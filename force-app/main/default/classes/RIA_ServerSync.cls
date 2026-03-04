/**
 * Optional server-side sync.
 *
 * Requires a Named Credential (classic) with name RIA_Self (default) that points to your org domain,
 * and uses OAuth so Apex callouts can reach Tooling API endpoints.
 *
 * This is intentionally optional because browser sync avoids the need for org-specific callout config.
 *
 * Implementation detail: processes Tooling API pagination one page per Queueable to stay within
 * governor limits in large orgs.
 */
public with sharing class RIA_ServerSync implements Queueable, Database.AllowsCallouts {

    private String syncRunId;
    private String nextUrl;
    private Integer page;

    public class ServerSyncCheckResult {
        @AuraEnabled public Boolean ok;
        @AuraEnabled public String message;
    }

    public RIA_ServerSync(String syncRunId, String nextUrl, Integer page) {
        this.syncRunId = syncRunId;
        this.nextUrl = nextUrl;
        this.page = page == null ? 1 : page;
    }

    @AuraEnabled
    public static ServerSyncCheckResult testConnection() {
        ServerSyncCheckResult r = new ServerSyncCheckResult();
        try {
            HttpRequest req = new HttpRequest();
            req.setMethod('GET');
            req.setEndpoint('callout:' + RIA_Settings.defaultNamedCredential()
                + '/services/data/v' + RIA_Settings.apiVersion()
                + '/tooling/query?q=' + EncodingUtil.urlEncode('SELECT Id FROM ApexClass LIMIT 1', 'UTF-8'));
            HttpResponse res = new Http().send(req);
            r.ok = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
            r.message = r.ok ? 'Callout OK.' : ('Callout failed: ' + res.getStatusCode() + ' ' + res.getStatus());
        } catch (Exception ex) {
            r.ok = false;
            r.message = ex.getMessage();
        }
        return r;
    }

    @AuraEnabled
    public static void enqueue() {
        // Start a new run and enqueue page 1
        RIA_GraphService.SyncStart s = RIA_GraphService.startSync('Server');

        String soql =
            'SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType,' +
            ' RefMetadataComponentId, RefMetadataComponentName, RefMetadataComponentType' +
            ' FROM MetadataComponentDependency' +
            ' WHERE (MetadataComponentType IN (\'ApexClass\',\'Flow\',\'LightningComponentBundle\',\'CustomField\',\'CustomObject\',\'PermissionSet\',\'Profile\',\'FlexiPage\')' +
            ' OR RefMetadataComponentType IN (\'ApexClass\',\'Flow\',\'LightningComponentBundle\',\'CustomField\',\'CustomObject\',\'PermissionSet\',\'Profile\',\'FlexiPage\'))';

        String firstUrl = '/services/data/v' + RIA_Settings.apiVersion() + '/tooling/query?q=' + EncodingUtil.urlEncode(soql, 'UTF-8');
        System.enqueueJob(new RIA_ServerSync(s.syncRunId, firstUrl, 1));
    }

    public void execute(QueueableContext context) {
        try {
            processOnePage();
        } catch (Exception ex) {
            markFailed(ex);
            throw ex;
        }
    }

    private void processOnePage() {
        if (String.isBlank(syncRunId) || String.isBlank(nextUrl)) {
            throw new AuraHandledException('Server sync misconfigured: missing syncRunId or nextUrl.');
        }

        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint('callout:' + RIA_Settings.defaultNamedCredential() + nextUrl);
        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new AuraHandledException('Tooling query failed: ' + res.getStatusCode() + ' ' + res.getStatus());
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) parsed.get('records');
        String nextRecordsUrl = (String) parsed.get('nextRecordsUrl');

        RIA_GraphService.GraphChunk chunk = new RIA_GraphService.GraphChunk();
        chunk.nodes = new List<RIA_GraphService.NodePayload>();
        chunk.edges = new List<RIA_GraphService.EdgePayload>();

        Datetime nowDt = Datetime.now();

        // Use metadata Ids for External Ids.
        Set<String> seenNodeExt = new Set<String>();

        for (Object recObj : records) {
            Map<String, Object> rec = (Map<String, Object>) recObj;
            String mType = (String) rec.get('MetadataComponentType');
            String mName = (String) rec.get('MetadataComponentName');
            String mId = (String) rec.get('MetadataComponentId');

            String rType = (String) rec.get('RefMetadataComponentType');
            String rName = (String) rec.get('RefMetadataComponentName');
            String rId = (String) rec.get('RefMetadataComponentId');

            String fromExt = makeExternalId(mId, mType, mName);
            String toExt = makeExternalId(rId, rType, rName);

            if (!seenNodeExt.contains(fromExt)) {
                seenNodeExt.add(fromExt);
                chunk.nodes.add(makeNode(fromExt, mType, mName, mId, nowDt));
            }
            if (!seenNodeExt.contains(toExt)) {
                seenNodeExt.add(toExt);
                chunk.nodes.add(makeNode(toExt, rType, rName, rId, nowDt));
            }

            RIA_GraphService.EdgePayload ep = new RIA_GraphService.EdgePayload();
            ep.relationship = 'DependsOn';
            ep.fromExternalId = fromExt;
            ep.toExternalId = toExt;
            ep.externalId = fromExt + '->' + toExt + '|DependsOn';
            ep.lastSeen = nowDt;
            chunk.edges.add(ep);
        }

        // Ingest the page
        RIA_GraphService.upsertGraphChunk(syncRunId, JSON.serialize(chunk));

        // Continue or finalize
        if (!String.isBlank(nextRecordsUrl)) {
            // Safety limit: avoid infinite loops due to unexpected API behavior.
            Integer nextPage = (page == null ? 1 : page) + 1;
            if (nextPage > 500) {
                throw new AuraHandledException('Server sync aborted: exceeded 500 pagination pages (safety limit).');
            }
            System.enqueueJob(new RIA_ServerSync(syncRunId, nextRecordsUrl, nextPage));
        } else {
            RIA_GraphService.finishSync(syncRunId);
        }
    }

    private static RIA_GraphService.NodePayload makeNode(String extId, String type, String name, String metadataId, Datetime lastSeen) {
        RIA_GraphService.NodePayload n = new RIA_GraphService.NodePayload();
        n.externalId = extId;
        n.type = type;
        n.name = name;
        n.metadataId = metadataId;
        n.lastSeen = lastSeen;
        return n;
    }

    private static String makeExternalId(String metadataId, String type, String name) {
        if (!String.isBlank(metadataId)) return metadataId.trim();
        String fallback = String.valueOf(type) + '|' + String.valueOf(name);
        return fallback.length() > 255 ? fallback.substring(0, 255) : fallback;
    }

    private void markFailed(Exception ex) {
        try {
            RIA_Sync_Run__c run = [
                SELECT Id
                FROM RIA_Sync_Run__c
                WHERE Id = :syncRunId
                LIMIT 1
            ];
            run.Status__c = 'Failed';
            run.Finished_At__c = Datetime.now();
            run.Message__c = ex.getMessage();
            update run;
        } catch (Exception ignore) {}
    }
}
