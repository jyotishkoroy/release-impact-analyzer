public with sharing class RIA_SyncScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        RIA_ServerSync.enqueue();
    }

    // Schedule string format: standard Cron (Salesforce).
    // Example: "0 0 2 * * ?" (2:00 AM daily)
    @AuraEnabled
    public static String schedule(String cronExpr) {
        if (String.isBlank(cronExpr)) {
            cronExpr = '0 0 2 * * ?';
        }
        String name = 'RIA_ServerSync';
        return System.schedule(name, cronExpr, new RIA_SyncScheduler());
    }

    @AuraEnabled
    public static void abort(String jobId) {
        if (String.isBlank(jobId)) return;
        System.abortJob(jobId);
    }
}
