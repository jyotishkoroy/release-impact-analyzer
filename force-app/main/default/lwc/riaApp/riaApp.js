import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getSummary from '@salesforce/apex/RIA_AppController.getSummary';
import startSync from '@salesforce/apex/RIA_AppController.startSync';
import upsertGraphChunk from '@salesforce/apex/RIA_AppController.upsertGraphChunk';
import finishSync from '@salesforce/apex/RIA_AppController.finishSync';
import searchNodes from '@salesforce/apex/RIA_AppController.searchNodes';
import generateImpact from '@salesforce/apex/RIA_AppController.generateImpact';
import testServerSync from '@salesforce/apex/RIA_AppController.testServerSync';
import runServerSyncNow from '@salesforce/apex/RIA_AppController.runServerSyncNow';
import scheduleServerSync from '@salesforce/apex/RIA_AppController.scheduleServerSync';

const DEFAULT_API_VERSION = '55.0';
const TOOLING_ENDPOINT = (soql) => `/services/data/v${DEFAULT_API_VERSION}/tooling/query?q=${encodeURIComponent(soql)}`;

const TYPE_OPTIONS = [
    { label: 'ApexClass', value: 'ApexClass' },
    { label: 'Flow', value: 'Flow' },
    { label: 'LightningComponentBundle', value: 'LightningComponentBundle' },
    { label: 'CustomObject', value: 'CustomObject' },
    { label: 'CustomField', value: 'CustomField' },
    { label: 'PermissionSet', value: 'PermissionSet' },
    { label: 'Profile', value: 'Profile' },
    { label: 'FlexiPage', value: 'FlexiPage' }
];

const ACTION_OPTIONS = [
    { label: 'MODIFY', value: 'MODIFY' },
    { label: 'DELETE', value: 'DELETE' },
    { label: 'RENAME', value: 'RENAME' }
];

export default class RiaApp extends LightningElement {
    @track summary;
    @track syncing = false;
    @track syncProgress = 0;
    @track syncLabel = '';
    @track suggestions = [];

    @track changeItems = [];
    @track pasteText = '';

    @track impactReport;

    newType = 'ApexClass';
    newAction = 'MODIFY';
    searchTerm = '';
    picked = null;

    cronExpr = '0 0 2 * * ?';

    connectedCallback() {
        this.refreshSummary();
    }

    get typeOptions() { return TYPE_OPTIONS; }
    get actionOptions() { return ACTION_OPTIONS; }

    get addDisabled() {
        return !this.picked;
    }

    get impactDisabled() {
        return this.syncing || this.changeItems.length === 0;
    }

    async refreshSummary() {
        try {
            this.summary = await getSummary();
        } catch (e) {
            this.toast('Error', this.humanError(e), 'error');
        }
    }

    // ===== Sync =====

    async handleBrowserSync() {
        if (this.syncing) return;
        this.syncing = true;
        this.syncProgress = 1;
        this.syncLabel = 'Starting sync run...';

        let run;
        try {
            run = await startSync({ mode: 'Browser' });
        } catch (e) {
            this.syncing = false;
            this.toast('Sync failed', this.humanError(e), 'error');
            return;
        }

        try {
            await this.ingestDependenciesViaBrowser(run.syncRunId);
            const fin = await finishSync({ syncRunId: run.syncRunId });
            this.toast('Sync complete', `Edges deleted (stale): ${fin.edgesDeleted}`, 'success');
        } catch (e) {
            this.toast('Sync failed', this.humanError(e), 'error');
        } finally {
            this.syncing = false;
            this.syncProgress = 0;
            this.syncLabel = '';
            await this.refreshSummary();
        }
    }

    async ingestDependenciesViaBrowser(syncRunId) {
        // Conservative SOQL filter to keep rows manageable in very large orgs.
        const soql =
            "SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType," +
            " RefMetadataComponentId, RefMetadataComponentName, RefMetadataComponentType" +
            " FROM MetadataComponentDependency" +
            " WHERE (MetadataComponentType IN ('ApexClass','Flow','LightningComponentBundle','CustomField','CustomObject','PermissionSet','Profile','FlexiPage')" +
            " OR RefMetadataComponentType IN ('ApexClass','Flow','LightningComponentBundle','CustomField','CustomObject','PermissionSet','Profile','FlexiPage'))";

        let nextUrl = TOOLING_ENDPOINT(soql);
        let pages = 0;
        let totalEdges = 0;

        while (nextUrl && pages < 200) {
            pages++;
            this.syncLabel = `Fetching Tooling dependency page ${pages}...`;
            this.syncProgress = Math.min(95, 1 + pages); // soft progress

            const data = await this.fetchJson(nextUrl);
            const records = data.records || [];
            const chunk = this.buildGraphChunk(records);

            totalEdges += (chunk.edges || []).length;

            // Send chunk to Apex
            await upsertGraphChunk({ syncRunId, chunkJson: JSON.stringify(chunk) });

            nextUrl = data.nextRecordsUrl; // relative URL
        }

        this.syncLabel = `Ingested ${totalEdges} dependencies. Finalizing...`;
        this.syncProgress = 98;
    }

    buildGraphChunk(records) {
        const nowIso = new Date().toISOString();
        const nodesMap = new Map(); // externalId -> payload
        const edges = [];

        const addNode = (type, name, metadataId) => {
    // Prefer stable 18-char Metadata Ids (Tooling API) to keep External Ids safely under 255 chars.
    // Fallback to "Type|Name" if an Id isn't available.
    const ext = (metadataId && String(metadataId).trim())
        ? String(metadataId).trim()
        : `${type}|${name}`.slice(0, 255);

    if (!nodesMap.has(ext)) {
        nodesMap.set(ext, {
            externalId: ext,
            type,
            name,
            metadataId: metadataId || null,
            namespace: null,
            lastSeen: nowIso
        });
    }
    return ext;
};

        for (const r of records) {
            const mType = r.MetadataComponentType;
            const mName = r.MetadataComponentName;
            const mId = r.MetadataComponentId;

            const refType = r.RefMetadataComponentType;
            const refName = r.RefMetadataComponentName;
            const refId = r.RefMetadataComponentId;

            if (!mType || !mName || !refType || !refName) continue;

            const fromExt = addNode(mType, mName, mId);
            const toExt = addNode(refType, refName, refId);

            edges.push({
                externalId: `${fromExt}->${toExt}|DependsOn`,
                fromExternalId: fromExt,
                toExternalId: toExt,
                relationship: 'DependsOn',
                lastSeen: nowIso
            });
        }

        return {
            nodes: Array.from(nodesMap.values()),
            edges
        };
    }

    async handleTestServerSync() {
        try {
            const r = await testServerSync();
            this.toast(r.ok ? 'Server sync ready' : 'Server sync not ready', r.message, r.ok ? 'success' : 'warning');
        } catch (e) {
            this.toast('Server sync test failed', this.humanError(e), 'error');
        }
    }

    async handleRunServerSync() {
        try {
            await runServerSyncNow();
            this.toast('Server sync queued', 'A queueable job was enqueued. Check Setup → Apex Jobs for status.', 'success');
        } catch (e) {
            this.toast('Server sync failed', this.humanError(e), 'error');
        }
    }

    async handleSchedule() {
        try {
            const jobId = await scheduleServerSync({ cronExpr: this.cronExpr });
            this.toast('Scheduled', `Server sync scheduled. Job Id: ${jobId}`, 'success');
        } catch (e) {
            this.toast('Scheduling failed', this.humanError(e), 'error');
        }
    }

    handleCronChange(e) {
        this.cronExpr = e.target.value;
    }

    // ===== Change Set =====

    handleTypeChange(e) {
        this.newType = e.detail.value;
        this.picked = null;
        this.suggestions = [];
    }

    handleActionChange(e) {
        this.newAction = e.detail.value;
    }

    handleSearchTermChange(e) {
        this.searchTerm = e.target.value;
    }

    async handleSearchKeyUp() {
        const term = (this.searchTerm || '').trim();
        if (term.length < 2) {
            this.suggestions = [];
            return;
        }
        try {
            const rows = await searchNodes({ typeFilter: this.newType, searchTerm: term, limitSize: 12 });
            this.suggestions = (rows || []).map(r => ({
                id: r.id,
                type: r.type,
                name: r.name,
                externalId: r.externalId
            }));
        } catch (e) {
            // silent to avoid spam while typing
        }
    }

    handlePickSuggestion(e) {
        const externalId = e.currentTarget.dataset.externalid;
        const name = e.currentTarget.dataset.name;
        const type = e.currentTarget.dataset.type;
        this.picked = { externalId, name, type };
        this.searchTerm = name;
        this.suggestions = [];
    }

    handleAddSelected() {
        if (!this.picked) return;

        const action = this.newAction;
        const item = {
            key: `${Date.now()}-${Math.random()}`,
            type: this.picked.type,
            name: this.picked.name,
            action,
            newName: '',
            isRename: action === 'RENAME'
        };

        this.changeItems = [item, ...this.changeItems];
        this.picked = null;
        this.searchTerm = '';
    }

    handleRemove(e) {
        const idx = Number(e.currentTarget.dataset.index);
        this.changeItems = this.changeItems.filter((_, i) => i !== idx);
    }

    handleRenameInput(e) {
        const idx = Number(e.currentTarget.dataset.index);
        const val = e.target.value;
        this.changeItems = this.changeItems.map((c, i) => i === idx ? { ...c, newName: val } : c);
    }

    handlePasteChange(e) {
        this.pasteText = e.target.value;
    }

    handleParsePaste() {
        const lines = (this.pasteText || '').split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        const added = [];
        for (const line of lines) {
            // Format: Type Name [Action]
            const parts = line.split(/\s+/);
            if (parts.length < 2) continue;
            const type = parts[0];
            const action = (parts[parts.length - 1] || 'MODIFY').toUpperCase();
            const hasAction = ACTION_OPTIONS.some(o => o.value === action);
            const name = hasAction ? parts.slice(1, -1).join(' ') : parts.slice(1).join(' ');
            const a = hasAction ? action : 'MODIFY';

            added.push({
                key: `${Date.now()}-${Math.random()}`,
                type,
                name,
                action: a,
                newName: '',
                isRename: a === 'RENAME'
            });
        }
        this.changeItems = [...added, ...this.changeItems];
        this.toast('Imported', `Added ${added.length} items`, 'success');
    }

    handleClearChangeSet() {
        this.changeItems = [];
        this.pasteText = '';
        this.impactReport = null;
    }

    // ===== Impact =====

    async handleGenerateImpact() {
        if (this.changeItems.length === 0) return;

        const payload = this.changeItems.map(c => ({
            type: c.type,
            name: c.name,
            action: c.action,
            newName: c.newName
        }));

        try {
            this.impactReport = await generateImpact({ changeSetJson: JSON.stringify(payload), maxDepth: 5 });
            // decorate for UI
            this.impactReport.nodes = (this.impactReport.nodes || []).map(n => ({
                ...n,
                rowClass: n.isChanged ? 'rowChanged' : ''
            }));
            this.impactReport.checklist = (this.impactReport.checklist || []).map(c => {
    const severityLower = (c.severity || '').toLowerCase();
    return { ...c, severityLower, className: `checkitem ${severityLower}` };
});
            this.toast('Impact generated', `Impacted: ${this.impactReport.nodes.length}`, 'success');
        } catch (e) {
            this.toast('Impact failed', this.humanError(e), 'error');
        }
    }

    get graphNodes() {
        return (this.impactReport?.nodes || []).map(n => ({
            id: n.id,
            label: n.name,
            type: n.type,
            depth: n.depth,
            isRoot: n.isChanged
        }));
    }

    get graphEdges() {
        return (this.impactReport?.edges || []).map(e => ({
            source: e.fromId,
            target: e.toId,
            relationship: e.relationship
        }));
    }

    get graphRootIds() {
        return (this.impactReport?.nodes || []).filter(n => n.isChanged).map(n => n.id);
    }

    get typeChips() {
        const m = this.impactReport?.countsByType || {};
        const keys = Object.keys(m).sort();
        return keys.map(k => ({ label: k, count: m[k] }));
    }

    // ===== Export =====

    async handleCopyMarkdown() {
        try {
            await navigator.clipboard.writeText(this.impactReport?.markdown || '');
            this.toast('Copied', 'Markdown copied to clipboard.', 'success');
        } catch (e) {
            this.toast('Copy failed', 'Clipboard access not available. Select and copy manually.', 'warning');
        }
    }

    handleDownloadMarkdown() {
        const text = this.impactReport?.markdown || '';
        const blob = new Blob([text], { type: 'text/markdown' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'release-impact-report.md';
        a.click();
        URL.revokeObjectURL(url);
    }

    // ===== Helpers =====

    async fetchJson(urlOrRelative) {
        const url = urlOrRelative.startsWith('http') ? urlOrRelative : urlOrRelative;
        const res = await fetch(url, {
            method: 'GET',
            headers: { 'Content-Type': 'application/json' }
        });
        if (!res.ok) {
            const body = await res.text();
            throw new Error(`HTTP ${res.status} ${res.statusText}: ${body}`);
        }
        return res.json();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    humanError(e) {
        // Apex errors often come back as {body:{message}} or {body:{pageErrors}}
        try {
            if (e?.body?.message) return e.body.message;
            if (Array.isArray(e?.body) && e.body[0]?.message) return e.body[0].message;
            if (e?.message) return e.message;
            return JSON.stringify(e);
        } catch {
            return String(e);
        }
    }
}
