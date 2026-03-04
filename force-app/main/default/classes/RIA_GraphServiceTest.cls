@IsTest
private class RIA_GraphServiceTest {

    @IsTest
    static void testSyncLifecycleAndUpsertChunk() {
        Test.startTest();
        RIA_GraphService.SyncStart start = RIA_GraphService.startSync('Browser');

        // Build a minimal graph chunk
        RIA_GraphService.GraphChunk chunk = new RIA_GraphService.GraphChunk();
        chunk.nodes = new List<RIA_GraphService.NodePayload>();
        chunk.edges = new List<RIA_GraphService.EdgePayload>();

        Datetime nowDt = Datetime.now();

        RIA_GraphService.NodePayload a = new RIA_GraphService.NodePayload();
        a.externalId = 'ApexClass|MyClass';
        a.type = 'ApexClass';
        a.name = 'MyClass';
        a.lastSeen = nowDt;
        chunk.nodes.add(a);

        RIA_GraphService.NodePayload f = new RIA_GraphService.NodePayload();
        f.externalId = 'CustomField|Account.MyField__c';
        f.type = 'CustomField';
        f.name = 'Account.MyField__c';
        f.lastSeen = nowDt;
        chunk.nodes.add(f);

        RIA_GraphService.EdgePayload e = new RIA_GraphService.EdgePayload();
        e.externalId = a.externalId + '->' + f.externalId + '|DependsOn';
        e.fromExternalId = a.externalId;
        e.toExternalId = f.externalId;
        e.relationship = 'DependsOn';
        e.lastSeen = nowDt;
        chunk.edges.add(e);

        RIA_GraphService.ChunkUpsertResult res = RIA_GraphService.upsertGraphChunk(start.syncRunId, JSON.serialize(chunk));
        System.assertEquals(2, res.nodesUpserted);
        System.assertEquals(1, res.edgesUpserted);

        RIA_GraphService.SyncFinish fin = RIA_GraphService.finishSync(start.syncRunId);
        System.assertEquals('Success', fin.status);

        Test.stopTest();

        // Summary should be non-zero
        RIA_GraphService.SyncSummary sum = RIA_GraphService.getSummary();
        System.assert(sum.nodeCount >= 2, 'Expected nodeCount >= 2');
        System.assert(sum.edgeCount >= 1, 'Expected edgeCount >= 1');
    }
}
