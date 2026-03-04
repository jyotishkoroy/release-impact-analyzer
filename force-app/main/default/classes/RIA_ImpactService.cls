public with sharing class RIA_ImpactService {

    public class ChangeItem {
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public String action;   // MODIFY | DELETE | RENAME
        @AuraEnabled public String newName;  // for RENAME
    }

    public class ImpactNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public Integer depth;
        @AuraEnabled public Boolean isChanged;
        @AuraEnabled public String action;
    }

    public class ImpactEdge {
        @AuraEnabled public Id fromId;
        @AuraEnabled public Id toId;
        @AuraEnabled public String relationship;
    }

    public class ChecklistItem {
        @AuraEnabled public String category;
        @AuraEnabled public String text;
        @AuraEnabled public String severity; // INFO | WARN | HIGH
    }

    public class ImpactReport {
        @AuraEnabled public List<ImpactNode> nodes;
        @AuraEnabled public List<ImpactEdge> edges;
        @AuraEnabled public Map<String, Integer> countsByType;
        @AuraEnabled public List<ChecklistItem> checklist;
        @AuraEnabled public String markdown;
        @AuraEnabled public String jiraText;
    }

    @AuraEnabled
    public static ImpactReport generateImpact(String changeSetJson, Integer maxDepth) {
        if (String.isBlank(changeSetJson)) {
            throw new AuraHandledException('Provide a change set (JSON).');
        }

        Integer depthLimit = (maxDepth == null || maxDepth <= 0 || maxDepth > 10) ? 5 : maxDepth;

        List<ChangeItem> changes = (List<ChangeItem>) JSON.deserialize(changeSetJson, List<ChangeItem>.class);
        if (changes == null || changes.isEmpty()) {
            throw new AuraHandledException('Change set is empty.');
        }

        // Map changed nodes
        Map<Id, ChangeItem> changedById = new Map<Id, ChangeItem>();
        Set<Id> changedIds = new Set<Id>();

        // Resolve by type + name (exact match)
        Set<String> types = new Set<String>();
        Set<String> names = new Set<String>();
        for (ChangeItem c : changes) {
            if (c == null) continue;
            if (!String.isBlank(c.type)) types.add(c.type.trim());
            if (!String.isBlank(c.name)) names.add(c.name.trim());
        }
        if (types.isEmpty() || names.isEmpty()) {
            throw new AuraHandledException('Each change item needs type + name.');
        }

        List<RIA_Node__c> matches = [
            SELECT Id, Component_Type__c, Component_Name__c
            FROM RIA_Node__c
            WHERE Component_Type__c IN :types AND Component_Name__c IN :names
        ];

        Map<String, Id> keyToId = new Map<String, Id>();
        for (RIA_Node__c n : matches) {
            keyToId.put(makeKey(n.Component_Type__c, n.Component_Name__c), n.Id);
        }

        for (ChangeItem c : changes) {
            if (c == null) continue;
            String k = makeKey(c.type, c.name);
            Id idVal = keyToId.get(k);
            if (idVal != null) {
                changedIds.add(idVal);
                changedById.put(idVal, c);
            }
        }

        if (changedIds.isEmpty()) {
            throw new AuraHandledException('No changed components matched the stored graph. Sync first, or use autocomplete selection.');
        }

        // BFS over INCOMING edges (who depends on the changed items)
        Map<Id, Integer> depthByNode = new Map<Id, Integer>();
        Set<Id> impacted = new Set<Id>();
        impacted.addAll(changedIds);

        Set<Id> frontier = new Set<Id>();
        for (Id cid : changedIds) {
            depthByNode.put(cid, 0);
            frontier.add(cid);
        }

        List<RIA_Edge__c> collectedEdges = new List<RIA_Edge__c>();

        for (Integer depth = 0; depth < depthLimit && !frontier.isEmpty(); depth++) {
            List<RIA_Edge__c> edges = [
                SELECT Id, From_Node__c, To_Node__c, Relationship__c
                FROM RIA_Edge__c
                WHERE To_Node__c IN :frontier
            ];
            Set<Id> nextFrontier = new Set<Id>();
            for (RIA_Edge__c e : edges) {
                collectedEdges.add(e);
                Id dependentId = e.From_Node__c; // component that references frontier node
                if (!depthByNode.containsKey(dependentId)) {
                    depthByNode.put(dependentId, depth + 1);
                    nextFrontier.add(dependentId);
                    impacted.add(dependentId);
                }
            }
            frontier = nextFrontier;
        }

        // Load nodes
        Map<Id, RIA_Node__c> nodes = new Map<Id, RIA_Node__c>([
            SELECT Id, Component_Type__c, Component_Name__c
            FROM RIA_Node__c
            WHERE Id IN :impacted
        ]);

        // Build ImpactReport DTO
        ImpactReport r = new ImpactReport();
        r.nodes = new List<ImpactNode>();
        r.edges = new List<ImpactEdge>();
        r.countsByType = new Map<String, Integer>();
        r.checklist = new List<ChecklistItem>();

        for (Id nid : nodes.keySet()) {
            RIA_Node__c n = nodes.get(nid);
            ImpactNode in = new ImpactNode();
            in.id = n.Id;
            in.type = n.Component_Type__c;
            in.name = n.Component_Name__c;
            in.depth = depthByNode.containsKey(n.Id) ? depthByNode.get(n.Id) : 999;
            in.isChanged = changedIds.contains(n.Id);
            ChangeItem ch = changedById.get(n.Id);
            in.action = ch == null ? 'MODIFY' : (String.isBlank(ch.action) ? 'MODIFY' : ch.action.toUpperCase());
            r.nodes.add(in);

            String t = String.valueOf(in.type);
            r.countsByType.put(t, (r.countsByType.containsKey(t) ? r.countsByType.get(t) : 0) + 1);
        }

        // Include only edges between included nodes
        Set<Id> allowed = nodes.keySet();
        for (RIA_Edge__c e : collectedEdges) {
            if (allowed.contains(e.From_Node__c) && allowed.contains(e.To_Node__c)) {
                ImpactEdge ie = new ImpactEdge();
                ie.fromId = e.From_Node__c;
                ie.toId = e.To_Node__c;
                ie.relationship = e.Relationship__c;
                r.edges.add(ie);
            }
        }

        // Checklist heuristics
        addChecklist(r, changes, nodes, changedIds);

        r.markdown = buildMarkdown(r, nodes, changedById);
        r.jiraText = r.markdown; // Jira supports Markdown-like formatting in many configs

        // sort nodes by depth then type/name
        r.nodes.sort(new ImpactNodeSort());

        return r;
    }

    private static void addChecklist(ImpactReport r, List<ChangeItem> changes, Map<Id, RIA_Node__c> nodes, Set<Id> changedIds) {
        // High-risk operations
        for (ChangeItem c : changes) {
            if (c == null) continue;
            String action = String.isBlank(c.action) ? 'MODIFY' : c.action.toUpperCase();
            if ((action == 'DELETE' || action == 'RENAME') && 'CustomField'.equalsIgnoreCase(c.type)) {
                r.checklist.add(makeItem('Field Change', 'Validate all references to field "' + c.name + '" (delete/rename).', 'HIGH'));
            }
        }

        // If impacted includes PermissionSet / Profile
        Integer perms = 0;
        Integer pages = 0;
        Integer flows = 0;
        Integer tests = 0;

        for (RIA_Node__c n : nodes.values()) {
            if (n.Component_Type__c == 'PermissionSet' || n.Component_Type__c == 'Profile') perms++;
            if (n.Component_Type__c == 'FlexiPage') pages++;
            if (n.Component_Type__c == 'Flow' || n.Component_Type__c == 'FlowDefinition') flows++;
            if (n.Component_Type__c == 'ApexClass' && isLikelyTest(n.Component_Name__c)) tests++;
        }

        if (perms > 0) r.checklist.add(makeItem('Access', 'Review impacted profiles/permission sets (' + perms + ').', 'WARN'));
        if (pages > 0) r.checklist.add(makeItem('UI', 'Validate Lightning pages (FlexiPages) impacted (' + pages + ').', 'WARN'));
        if (flows > 0) r.checklist.add(makeItem('Automation', 'Re-test impacted Flows (' + flows + ') and confirm activation state.', 'WARN'));
        if (tests > 0) r.checklist.add(makeItem('Testing', 'Run impacted Apex tests (heuristic) (' + tests + ').', 'INFO'));

        // Default checklist items
        r.checklist.add(makeItem('Deployment', 'Confirm dependencies included in deployment artifact (fields, objects, flows, pages).', 'INFO'));
        r.checklist.add(makeItem('Post-Deploy', 'Smoke test key business flows + UI navigation items.', 'INFO'));
    }

    private static ChecklistItem makeItem(String cat, String text, String sev) {
        ChecklistItem i = new ChecklistItem();
        i.category = cat;
        i.text = text;
        i.severity = sev;
        return i;
    }

    private static Boolean isLikelyTest(String className) {
        if (String.isBlank(className)) return false;
        String n = className.toLowerCase();
        return n.endsWith('test') || n.contains('test_') || n.contains('_test') || n.contains('testclass');
    }

    private static String buildMarkdown(ImpactReport r, Map<Id, RIA_Node__c> nodes, Map<Id, ChangeItem> changedById) {
        StringBuilder sb = new StringBuilder();

        sb.append('## Release Impact Analyzer\n\n');
        sb.append('### Summary\n');
        sb.append('- Total impacted components: **').append(String.valueOf(r.nodes.size())).append('**\n');

        // counts by type
        List<String> types = new List<String>(r.countsByType.keySet());
        types.sort();
        sb.append('- By type: ');
        for (Integer i = 0; i < types.size(); i++) {
            String t = types[i];
            sb.append(t).append(' (').append(String.valueOf(r.countsByType.get(t))).append(')');
            if (i < types.size() - 1) sb.append(', ');
        }
        sb.append('\n\n');

        sb.append('### Changed Components\n');
        for (ImpactNode n : r.nodes) {
            if (!n.isChanged) continue;
            sb.append('- **').append(n.type).append('**: ').append(n.name).append(' — ').append(n.action).append('\n');
        }
        sb.append('\n');

        sb.append('### Impacted Components (blast radius)\n');
        for (ImpactNode n : r.nodes) {
            if (n.isChanged) continue;
            sb.append('- [d').append(String.valueOf(n.depth)).append('] **').append(n.type).append('**: ').append(n.name).append('\n');
        }
        sb.append('\n');

        sb.append('### Deploy Readiness Checklist\n');
        for (ChecklistItem c : r.checklist) {
            sb.append('- **').append(c.severity).append('** [').append(c.category).append('] ').append(c.text).append('\n');
        }
        sb.append('\n');

        sb.append('---\n');
        sb.append('_Generated by Release Impact Analyzer._\n');
        return sb.toString();
    }

    private static String makeKey(String type, String name) {
        return String.valueOf(type).trim() + '|' + String.valueOf(name).trim();
    }

    private class ImpactNodeSort implements Comparator<ImpactNode> {
        public Integer compare(ImpactNode a, ImpactNode b) {
            Integer da = a == null || a.depth == null ? 999 : a.depth;
            Integer db = b == null || b.depth == null ? 999 : b.depth;
            if (da != db) return da < db ? -1 : 1;

            String ta = a == null ? '' : String.valueOf(a.type);
            String tb = b == null ? '' : String.valueOf(b.type);
            Integer tcmp = ta.compareTo(tb);
            if (tcmp != 0) return tcmp;

            String na = a == null ? '' : String.valueOf(a.name);
            String nb = b == null ? '' : String.valueOf(b.name);
            return na.compareTo(nb);
        }
    }
}
