public with sharing class RIA_AppController {
    @AuraEnabled(cacheable=true)
    public static RIA_GraphService.SyncSummary getSummary() {
        return RIA_GraphService.getSummary();
    }

    @AuraEnabled
    public static RIA_GraphService.SyncStart startSync(String mode) {
        return RIA_GraphService.startSync(mode);
    }

    @AuraEnabled
    public static RIA_GraphService.ChunkUpsertResult upsertGraphChunk(String syncRunId, String chunkJson) {
        return RIA_GraphService.upsertGraphChunk(syncRunId, chunkJson);
    }

    @AuraEnabled
    public static RIA_GraphService.SyncFinish finishSync(String syncRunId) {
        return RIA_GraphService.finishSync(syncRunId);
    }

    @AuraEnabled(cacheable=true)
    public static List<RIA_GraphService.NodePick> searchNodes(String typeFilter, String searchTerm, Integer limitSize) {
        return RIA_GraphService.searchNodes(typeFilter, searchTerm, limitSize);
    }

    @AuraEnabled
    public static RIA_ImpactService.ImpactReport generateImpact(String changeSetJson, Integer maxDepth) {
        return RIA_ImpactService.generateImpact(changeSetJson, maxDepth);
    }

    // Optional: schedule server sync (requires Named Credential).
    @AuraEnabled
    public static String scheduleServerSync(String cronExpr) {
        return RIA_SyncScheduler.schedule(cronExpr);
    }

    @AuraEnabled
    public static void abortServerSync(String jobId) {
        RIA_SyncScheduler.abort(jobId);
    }

    @AuraEnabled
    public static RIA_ServerSync.ServerSyncCheckResult testServerSync() {
        return RIA_ServerSync.testConnection();
    }

    @AuraEnabled
    public static void runServerSyncNow() {
        RIA_ServerSync.enqueue();
    }
}
