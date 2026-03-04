public with sharing class RIA_Settings {
    // Defaults used by both browser and server sync.
    public static String apiVersion() {
        // Keep aligned with package API version for broad compatibility.
        return '55.0';
    }

    public static String defaultNamedCredential() {
        return 'RIA_Self';
    }
}
