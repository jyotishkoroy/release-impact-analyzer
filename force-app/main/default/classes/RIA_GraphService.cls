import System.SecurityException;

public with sharing class RIA_GraphService {

    // ===== DTOs (AuraEnabled-friendly) =====
    public class SyncSummary {
        @AuraEnabled public Integer nodeCount;
        @AuraEnabled public Integer edgeCount;
        @AuraEnabled public String lastRunStatus;
        @AuraEnabled public Datetime lastRunStartedAt;
        @AuraEnabled public Datetime lastRunFinishedAt;
        @AuraEnabled public String lastRunMode;
        @AuraEnabled public String lastRunMessage;
    }

    public class SyncStart {
        @AuraEnabled public String syncRunId;
        @AuraEnabled public Datetime startedAt;
    }

    public class ChunkUpsertResult {
        @AuraEnabled public Integer nodesUpserted;
        @AuraEnabled public Integer edgesUpserted;
    }

    public class SyncFinish {
        @AuraEnabled public Integer edgesDeleted;
        @AuraEnabled public Datetime finishedAt;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    public class NodePick {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public String externalId;
    }

    // Payload models
    public class GraphChunk {
        @AuraEnabled public List<NodePayload> nodes;
        @AuraEnabled public List<EdgePayload> edges;
    }

    public class NodePayload {
        @AuraEnabled public String externalId;
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public String metadataId;
        @AuraEnabled public String namespace;
        @AuraEnabled public Datetime lastSeen;
    }

    public class EdgePayload {
        @AuraEnabled public String externalId;
        @AuraEnabled public String fromExternalId;
        @AuraEnabled public String toExternalId;
        @AuraEnabled public String relationship;
        @AuraEnabled public Datetime lastSeen;
    }

    // ===== Public API =====

    @AuraEnabled(cacheable=true)
    public static SyncSummary getSummary() {
        SyncSummary s = new SyncSummary();

        AggregateResult nr = [SELECT COUNT(Id) c FROM RIA_Node__c];
        AggregateResult er = [SELECT COUNT(Id) c FROM RIA_Edge__c];

        s.nodeCount = (Integer)nr.get('c');
        s.edgeCount = (Integer)er.get('c');

        List<RIA_Sync_Run__c> last = [
            SELECT Id, Mode__c, Started_At__c, Finished_At__c, Status__c, Message__c
            FROM RIA_Sync_Run__c
            ORDER BY Started_At__c DESC
            LIMIT 1
        ];
        if (!last.isEmpty()) {
            RIA_Sync_Run__c r = last[0];
            s.lastRunMode = r.Mode__c;
            s.lastRunStartedAt = r.Started_At__c;
            s.lastRunFinishedAt = r.Finished_At__c;
            s.lastRunStatus = r.Status__c;
            s.lastRunMessage = r.Message__c;
        }
        return s;
    }

    @AuraEnabled
    public static SyncStart startSync(String mode) {
        assertCrud();

        RIA_Sync_Run__c run = new RIA_Sync_Run__c(
            Name = 'RIA Sync ' + String.valueOf(Datetime.now().getTime()),
            Mode__c = String.isBlank(mode) ? 'Browser' : mode,
            Started_At__c = Datetime.now(),
            Status__c = 'Running',
            Nodes_Upserted__c = 0,
            Edges_Upserted__c = 0,
            Edges_Deleted__c = 0
        );
        insert run;

        SyncStart s = new SyncStart();
        s.syncRunId = run.Id;
        s.startedAt = run.Started_At__c;
        return s;
    }

    @AuraEnabled
    public static ChunkUpsertResult upsertGraphChunk(String syncRunId, String chunkJson) {
        assertCrud();

        if (String.isBlank(syncRunId)) {
            throw new AuraHandledException('Missing syncRunId.');
        }
        if (String.isBlank(chunkJson)) {
            throw new AuraHandledException('Empty chunk payload.');
        }

        GraphChunk chunk = (GraphChunk) JSON.deserialize(chunkJson, GraphChunk.class);
        if (chunk == null) {
            throw new AuraHandledException('Unable to parse chunk JSON.');
        }

        Datetime nowDt = Datetime.now();
        List<RIA_Node__c> nodeRows = new List<RIA_Node__c>();
        List<RIA_Edge__c> edgeRows = new List<RIA_Edge__c>();

        Set<String> nodeExtIds = new Set<String>();
        if (chunk.nodes != null) {
            for (NodePayload n : chunk.nodes) {
                if (n == null || String.isBlank(n.externalId) || String.isBlank(n.type) || String.isBlank(n.name)) continue;
                nodeExtIds.add(n.externalId);

                RIA_Node__c row = new RIA_Node__c();
                row.External_Id__c = n.externalId;
                row.Component_Type__c = n.type;
                row.Component_Name__c = n.name;
                row.Metadata_Id__c = n.metadataId;
                row.Namespace__c = n.namespace;
                row.Last_Seen__c = n.lastSeen == null ? nowDt : n.lastSeen;
                row.Name = n.name.left(80);
                nodeRows.add(row);
            }
        }

        // Upsert nodes in chunks (10k rows per DML)
        Integer nodesUpserted = 0;
        for (List<RIA_Node__c> batch : chunkList(nodeRows, 10000)) {
            Database.UpsertResult[] res = Database.upsert(batch, RIA_Node__c.External_Id__c, false);
            nodesUpserted += countSuccess(res);
        }

        // Map externalId -> nodeId
        Map<String, Id> extToId = new Map<String, Id>();
        if (!nodeExtIds.isEmpty()) {
            for (RIA_Node__c n : [
                SELECT Id, External_Id__c
                FROM RIA_Node__c
                WHERE External_Id__c IN :nodeExtIds
            ]) {
                extToId.put(n.External_Id__c, n.Id);
            }
        }

        if (chunk.edges != null) {
            for (EdgePayload e : chunk.edges) {
                if (e == null) continue;
                if (String.isBlank(e.externalId) || String.isBlank(e.fromExternalId) || String.isBlank(e.toExternalId) || String.isBlank(e.relationship)) continue;

                Id fromId = extToId.get(e.fromExternalId);
                Id toId = extToId.get(e.toExternalId);
                if (fromId == null || toId == null) continue;

                RIA_Edge__c row = new RIA_Edge__c();
                row.External_Id__c = e.externalId;
                row.From_Node__c = fromId;
                row.To_Node__c = toId;
                row.Relationship__c = e.relationship;
                row.Last_Seen__c = e.lastSeen == null ? nowDt : e.lastSeen;
                row.Name = e.relationship + ' ' + String.valueOf(nowDt.getTime());
                edgeRows.add(row);
            }
        }

        Integer edgesUpserted = 0;
        for (List<RIA_Edge__c> batch : chunkList(edgeRows, 10000)) {
            Database.UpsertResult[] res = Database.upsert(batch, RIA_Edge__c.External_Id__c, false);
            edgesUpserted += countSuccess(res);
        }

        // Update sync run counters (best-effort, avoid row lock)
        try {
            RIA_Sync_Run__c run = [
                SELECT Id, Nodes_Upserted__c, Edges_Upserted__c
                FROM RIA_Sync_Run__c
                WHERE Id = :syncRunId
                LIMIT 1
                FOR UPDATE
            ];
            run.Nodes_Upserted__c = (run.Nodes_Upserted__c == null ? 0 : run.Nodes_Upserted__c) + nodesUpserted;
            run.Edges_Upserted__c = (run.Edges_Upserted__c == null ? 0 : run.Edges_Upserted__c) + edgesUpserted;
            update run;
        } catch (Exception ex) {
            // ignore counter updates to keep chunk ingestion resilient
        }

        ChunkUpsertResult out = new ChunkUpsertResult();
        out.nodesUpserted = nodesUpserted;
        out.edgesUpserted = edgesUpserted;
        return out;
    }

    @AuraEnabled
    public static SyncFinish finishSync(String syncRunId) {
        assertCrud();

        RIA_Sync_Run__c run = [
            SELECT Id, Started_At__c, Status__c
            FROM RIA_Sync_Run__c
            WHERE Id = :syncRunId
            LIMIT 1
        ];
        Datetime finished = Datetime.now();

        Integer deletedEdges = 0;
        try {
            // Delete edges not seen since this run started (stale dependencies).
            List<RIA_Edge__c> stale = [
                SELECT Id
                FROM RIA_Edge__c
                WHERE Last_Seen__c < :run.Started_At__c
                LIMIT 10000
            ];
            while (!stale.isEmpty()) {
                delete stale;
                deletedEdges += stale.size();
                stale = [
                    SELECT Id
                    FROM RIA_Edge__c
                    WHERE Last_Seen__c < :run.Started_At__c
                    LIMIT 10000
                ];
            }
        } catch (Exception ex) {
            // keep going; stale cleanup is best-effort
        }

        run.Finished_At__c = finished;
        run.Status__c = 'Success';
        run.Edges_Deleted__c = deletedEdges;
        update run;

        SyncFinish out = new SyncFinish();
        out.edgesDeleted = deletedEdges;
        out.finishedAt = finished;
        out.status = run.Status__c;
        out.message = 'Sync completed.';
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<NodePick> searchNodes(String typeFilter, String searchTerm, Integer limitSize) {
        Integer lim = (limitSize == null || limitSize <= 0 || limitSize > 50) ? 25 : limitSize;
        String term = String.isBlank(searchTerm) ? '%' : ('%' + searchTerm.trim() + '%');

        String type = String.isBlank(typeFilter) ? null : typeFilter.trim();
        List<RIA_Node__c> rows;
        if (type == null) {
            rows = [
                SELECT Id, Component_Type__c, Component_Name__c, External_Id__c
                FROM RIA_Node__c
                WHERE Component_Name__c LIKE :term
                ORDER BY Component_Type__c, Component_Name__c
                LIMIT :lim
            ];
        } else {
            rows = [
                SELECT Id, Component_Type__c, Component_Name__c, External_Id__c
                FROM RIA_Node__c
                WHERE Component_Type__c = :type AND Component_Name__c LIKE :term
                ORDER BY Component_Name__c
                LIMIT :lim
            ];
        }

        List<NodePick> out = new List<NodePick>();
        for (RIA_Node__c r : rows) {
            NodePick p = new NodePick();
            p.id = r.Id;
            p.type = r.Component_Type__c;
            p.name = r.Component_Name__c;
            p.externalId = r.External_Id__c;
            out.add(p);
        }
        return out;
    }

    // ===== Helpers =====

    private static void assertCrud() {
        if (!Schema.sObjectType.RIA_Node__c.isAccessible()
            || !Schema.sObjectType.RIA_Edge__c.isAccessible()
            || !Schema.sObjectType.RIA_Sync_Run__c.isAccessible()) {
            throw new AuraHandledException('Missing object access. Assign the Release_Impact_Analyzer permission set.');
        }
        if (!Schema.sObjectType.RIA_Node__c.isCreateable()
            || !Schema.sObjectType.RIA_Edge__c.isCreateable()
            || !Schema.sObjectType.RIA_Sync_Run__c.isCreateable()) {
            throw new AuraHandledException('Missing create access. Assign the Release_Impact_Analyzer permission set.');
        }
    }

    private static Integer countSuccess(Database.UpsertResult[] res) {
        Integer c = 0;
        for (Database.UpsertResult r : res) {
            if (r != null && r.isSuccess()) c++;
        }
        return c;
    }

    private static List<List<T>> chunkList<T>(List<T> input, Integer chunkSize) {
        List<List<T>> out = new List<List<T>>();
        if (input == null || input.isEmpty()) return out;
        Integer size = input.size();
        for (Integer i = 0; i < size; i += chunkSize) {
            Integer end = Math.min(i + chunkSize, size);
            out.add(input.subList(i, end));
        }
        return out;
    }
}
