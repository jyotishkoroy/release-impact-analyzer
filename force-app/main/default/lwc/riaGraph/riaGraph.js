import { LightningElement, api } from 'lwc';

export default class RiaGraph extends LightningElement {
    @api nodes = [];
    @api edges = [];
    @api rootIds = [];

    // pan/zoom state
    scale = 1;
    tx = 0;
    ty = 0;
    panning = false;
    panStartX = 0;
    panStartY = 0;

    get hasData() {
        return (this.nodes || []).length > 0;
    }

    get viewBox() {
        // Large viewBox; we pan within it
        return `0 0 2400 1400`;
    }

    get transform() {
        return `translate(${this.tx} ${this.ty}) scale(${this.scale})`;
    }

    // Build a deterministic layered layout from depth.
    get layout() {
        const nodes = (this.nodes || []).map(n => ({
            id: n.id,
            label: n.label,
            type: n.type,
            depth: Number.isFinite(n.depth) ? n.depth : 0,
            isRoot: !!n.isRoot
        }));

        const byDepth = new Map();
        for (const n of nodes) {
            const d = n.depth;
            if (!byDepth.has(d)) byDepth.set(d, []);
            byDepth.get(d).push(n);
        }

        const depths = Array.from(byDepth.keys()).sort((a,b) => a-b);
        const pos = new Map();

        const xStep = 340;
        const yStep = 92;

        for (const d of depths) {
            const layer = byDepth.get(d) || [];
            layer.sort((a,b) => (a.type + a.label).localeCompare(b.type + b.label));

            for (let i = 0; i < layer.length; i++) {
                const x = 120 + d * xStep;
                const y = 120 + i * yStep;
                pos.set(layer[i].id, { x, y, node: layer[i] });
            }
        }

        return { pos };
    }

    get dots() {
        const { pos } = this.layout;
        const dots = [];
        for (const [id, p] of pos.entries()) {
            const n = p.node;
            const w = 260;
            const h = 58;
            const rx = p.x - w/2;
            const ry = p.y - h/2;

            const shortLabel = (n.label || '').length > 26 ? (n.label.slice(0, 26) + '…') : n.label;

            dots.push({
                id,
                tx: `translate(0 0)`,
                rx, ry, w, h,
                cls: n.isRoot ? 'node node--root' : 'node',
                shortLabel,
                type: n.type,
                txLabel: p.x - w/2 + 12,
                tyLabel: p.y - 4,
                txType: p.x - w/2 + 12,
                tyType: p.y + 18
            });
        }
        return dots;
    }

    get lines() {
        const { pos } = this.layout;
        const out = [];
        const edges = this.edges || [];
        for (let i = 0; i < edges.length; i++) {
            const e = edges[i];
            const a = pos.get(e.source);
            const b = pos.get(e.target);
            if (!a || !b) continue;

            out.push({
                key: `${e.source}-${e.target}-${i}`,
                x1: a.x + 130, // right side of node-ish
                y1: a.y,
                x2: b.x - 130,
                y2: b.y
            });
        }
        return out;
    }

    zoomIn() { this.scale = Math.min(2.2, this.scale + 0.1); }
    zoomOut() { this.scale = Math.max(0.5, this.scale - 0.1); }
    reset() { this.scale = 1; this.tx = 0; this.ty = 0; }

    panStart(e) {
        this.panning = true;
        this.panStartX = e.clientX;
        this.panStartY = e.clientY;
    }
    panMove(e) {
        if (!this.panning) return;
        const dx = (e.clientX - this.panStartX);
        const dy = (e.clientY - this.panStartY);
        this.panStartX = e.clientX;
        this.panStartY = e.clientY;
        this.tx += dx;
        this.ty += dy;
    }
    panEnd() {
        this.panning = false;
    }
}
