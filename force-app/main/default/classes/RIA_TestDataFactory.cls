@IsTest
public class RIA_TestDataFactory {
    public static Id makeNode(String type, String name) {
        RIA_Node__c n = new RIA_Node__c(
            Name = name,
            External_Id__c = type + '|' + name,
            Component_Type__c = type,
            Component_Name__c = name,
            Last_Seen__c = Datetime.now()
        );
        insert n;
        return n.Id;
    }

    public static void makeEdge(Id fromId, Id toId) {
        RIA_Edge__c e = new RIA_Edge__c(
            Name = 'DependsOn',
            External_Id__c = String.valueOf(fromId) + '->' + String.valueOf(toId) + '|DependsOn',
            From_Node__c = fromId,
            To_Node__c = toId,
            Relationship__c = 'DependsOn',
            Last_Seen__c = Datetime.now()
        );
        insert e;
    }
}
