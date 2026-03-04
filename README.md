# Release Impact Analyzer (LWC + Apex)

A **metadata dependency + blast radius** analyzer for Salesforce releases.

It builds a normalized dependency graph (Flow ↔ Apex ↔ LWC ↔ Object ↔ Field ↔ PermissionSet/Profile ↔ FlexiPage) from the org’s **Tooling API** `MetadataComponentDependency` object, and then lets release managers paste/select a list of changed components to generate:

- **“If I delete/rename field X”** impact report (blast radius)
- **Deploy readiness checklist** (tests likely affected, permissions/pages/flows to review)
- **Exportable release notes** (Markdown + Jira-friendly text)

> Key design: **Browser-based sync (no Remote Site / Named Credential required)** via same-origin Tooling API calls from LWC.  
> Optional: **server-side scheduled sync** (requires a Named Credential).

## Deploy

### Option A — Salesforce CLI (recommended)

```bash
sf org login web --set-default --alias ria
sf project deploy start --source-dir force-app --target-org ria
```

### Option B — Metadata API

Deploy `manifest/package.xml` using your preferred tool.

## Setup

1. Assign Permission Set: **Release_Impact_Analyzer**
2. Open App Launcher → **Release Impact Analyzer** app → **Release Impact Analyzer** tab.
3. Go to **Sync** → click **Sync via Browser (recommended)**.

## Browser Sync vs Scheduled Sync

### Browser Sync (default)
- Uses `fetch('/services/data/vXX.X/tooling/query?...')` from LWC.
- Works in most orgs as long as the user has **API Enabled** + adequate setup/metadata access.
- No Remote Site Settings / Named Credentials.

### Scheduled Server Sync (optional)
If you need unattended nightly sync:
1. Create a Named Credential (classic) named **RIA_Self**
   - **URL**: your org domain (e.g. `https://mydomain.my.salesforce.com`)
   - **Identity Type**: Per User
   - **Authentication Protocol**: OAuth 2.0
2. In the app → **Settings** → test callout and schedule.

Salesforce Tooling API `MetadataComponentDependency` provides directional dependencies between metadata components (referencing component → referenced component).

## Notes / Limitations

- `MetadataComponentDependency` coverage varies by metadata type; some standard metadata references can be incomplete in some orgs.
- Very large orgs can have tens of thousands of dependency rows; use the built-in type filters to keep sync manageable.

## Repo structure

- `force-app/main/default/lwc/` — UI
- `force-app/main/default/classes/` — services/controllers + tests
- `force-app/main/default/objects/` — normalized graph storage (Node/Edge)
- `force-app/main/default/flexipages/` + `tabs/` + `applications/` — navigation entry point

## Security

- All Apex is `with sharing`
- CRUD/FLS guarded using `Security.stripInaccessible` before DML
- UI uses Lightning Data Service patterns and SLDS

