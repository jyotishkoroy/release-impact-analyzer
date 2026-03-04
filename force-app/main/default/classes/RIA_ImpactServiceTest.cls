@IsTest
private class RIA_ImpactServiceTest {
    @IsTest
    static void testImpactBfsIncoming() {
        // Field is referenced by Apex and Flow
        Id fieldId = RIA_TestDataFactory.makeNode('CustomField', 'Account.MyField__c');
        Id apexId = RIA_TestDataFactory.makeNode('ApexClass', 'MyClass');
        Id flowId = RIA_TestDataFactory.makeNode('Flow', 'MyFlow');

        // Dependencies: Apex -> Field, Flow -> Field
        RIA_TestDataFactory.makeEdge(apexId, fieldId);
        RIA_TestDataFactory.makeEdge(flowId, fieldId);

        // Changed item is the field
        List<RIA_ImpactService.ChangeItem> cs = new List<RIA_ImpactService.ChangeItem>();
        RIA_ImpactService.ChangeItem ci = new RIA_ImpactService.ChangeItem();
        ci.type = 'CustomField';
        ci.name = 'Account.MyField__c';
        ci.action = 'DELETE';
        cs.add(ci);

        Test.startTest();
        RIA_ImpactService.ImpactReport rep = RIA_ImpactService.generateImpact(JSON.serialize(cs), 3);
        Test.stopTest();

        System.assertNotEquals(null, rep);
        System.assert(rep.nodes.size() >= 3, 'Expected at least 3 nodes');
        System.assert(rep.edges.size() >= 2, 'Expected at least 2 edges');

        Boolean foundApex = false;
        Boolean foundFlow = false;
        for (RIA_ImpactService.ImpactNode n : rep.nodes) {
            if (n.type == 'ApexClass' && n.name == 'MyClass') foundApex = true;
            if (n.type == 'Flow' && n.name == 'MyFlow') foundFlow = true;
        }
        System.assert(foundApex, 'Expected Apex impacted');
        System.assert(foundFlow, 'Expected Flow impacted');
    }
}
