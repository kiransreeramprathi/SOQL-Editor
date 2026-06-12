import { LightningElement, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import executeQuery       from '@salesforce/apex/SoqlEditorController.executeQuery';
import executeQueryAll    from '@salesforce/apex/SoqlEditorController.executeQueryAll';
import executeToolingQuery from '@salesforce/apex/SoqlEditorController.executeToolingQuery';
import getObjects         from '@salesforce/apex/OrgMetadataController.getObjects';
import getFields          from '@salesforce/apex/OrgMetadataController.getFields';
import getOrgLimits       from '@salesforce/apex/OrgMetadataController.getOrgLimits';
import getRecord          from '@salesforce/apex/OrgMetadataController.getRecord';
import updateRecord       from '@salesforce/apex/OrgMetadataController.updateRecord';
import getPicklistValues  from '@salesforce/apex/OrgMetadataController.getPicklistValues';

const PAGE_SIZE  = 50;
const HISTORY_MAX = 20;
const AC_LIMIT   = 15;
const SAVED_MAX  = 50;

const DATE_LITERALS = [
    'TODAY','YESTERDAY','TOMORROW',
    'THIS_WEEK','LAST_WEEK','NEXT_WEEK',
    'THIS_MONTH','LAST_MONTH','NEXT_MONTH',
    'THIS_QUARTER','LAST_QUARTER','NEXT_QUARTER',
    'THIS_YEAR','LAST_YEAR','NEXT_YEAR',
    'THIS_FISCAL_QUARTER','LAST_FISCAL_QUARTER','NEXT_FISCAL_QUARTER',
    'THIS_FISCAL_YEAR','LAST_FISCAL_YEAR','NEXT_FISCAL_YEAR',
    'LAST_N_DAYS:n','NEXT_N_DAYS:n',
    'LAST_N_WEEKS:n','NEXT_N_WEEKS:n',
    'LAST_N_MONTHS:n','NEXT_N_MONTHS:n',
    'LAST_N_QUARTERS:n','NEXT_N_QUARTERS:n',
    'LAST_N_YEARS:n','NEXT_N_YEARS:n',
    'LAST_N_FISCAL_QUARTERS:n','NEXT_N_FISCAL_QUARTERS:n',
    'LAST_N_FISCAL_YEARS:n','NEXT_N_FISCAL_YEARS:n'
];

const TOOLING_OBJECTS = [
    { apiName:'ApexClass',              label:'Apex Class' },
    { apiName:'ApexTrigger',            label:'Apex Trigger' },
    { apiName:'ApexComponent',          label:'Visualforce Component' },
    { apiName:'ApexPage',               label:'Visualforce Page' },
    { apiName:'ApexLog',                label:'Apex Log' },
    { apiName:'CustomField',            label:'Custom Field' },
    { apiName:'CustomObject',           label:'Custom Object' },
    { apiName:'EntityDefinition',       label:'Entity Definition' },
    { apiName:'FieldDefinition',        label:'Field Definition' },
    { apiName:'ValidationRule',         label:'Validation Rule' },
    { apiName:'WorkflowRule',           label:'Workflow Rule' },
    { apiName:'FlowDefinitionView',     label:'Flow Definition' },
    { apiName:'FlowVersionView',        label:'Flow Version' },
    { apiName:'LightningComponentBundle', label:'LWC Bundle' },
    { apiName:'AuraDefinitionBundle',   label:'Aura Bundle' },
    { apiName:'StaticResource',         label:'Static Resource' },
    { apiName:'Profile',                label:'Profile' },
    { apiName:'PermissionSet',          label:'Permission Set' },
    { apiName:'Layout',                 label:'Layout' },
    { apiName:'EmailTemplate',          label:'Email Template' },
    { apiName:'Report',                 label:'Report' },
    { apiName:'Dashboard',              label:'Dashboard' },
    { apiName:'ContentDocument',        label:'Content Document' }
];

export default class SoqlEditor extends LightningElement {
    @api utilityMode = false;

    // ── SOQL tab ──────────────────────────────────────────────
    @track query         = 'SELECT Id, Name FROM Account LIMIT 10';
    @track columns       = [];
    @track queryResult   = null;
    @track isLoading     = false;
    @track errorMessage  = '';
    @track currentPage   = 1;
    @track useToolingApi = false;
    @track useQueryAll   = false;
    @track resultFilter  = '';
    _sortCol = '';
    _sortAsc = true;
    _qh = [];

    // ── Autocomplete ──────────────────────────────────────────
    @track acSuggestions = [];
    @track acVisible     = false;
    @track acIndex       = -1;
    _metaCache     = {};
    _picklistCache = {};
    _acContext     = null;

    // ── Saved queries ─────────────────────────────────────────
    @track savedQueriesList = [];
    @track showSaveInput    = false;
    @track newQueryName     = '';

    // ── Object Inspector tab ──────────────────────────────────
    @track allObjects       = [];
    @track isLoadingObjects = false;
    @track objectSearch     = '';
    @track selectedObject   = null;
    @track inspectorFields  = [];
    @track fieldSearch      = '';

    // ── Record Inspector tab ──────────────────────────────────
    @track inspectRecordId   = '';
    @track recordFields      = null;
    @track isLoadingRecord   = false;
    @track recordObjectType  = '';
    @track recordFieldSearch = '';
    @track recordFieldMeta   = {};
    @track editMode          = false;
    @track editValues        = {};

    // ── Org Limits tab ────────────────────────────────────────
    @track orgLimits       = {};
    @track isLoadingLimits = false;

    objectsLoaded = false;

    // ════════════════════════════════════════════════════════
    //  LIFECYCLE
    // ════════════════════════════════════════════════════════
    connectedCallback() {
        this.loadObjects();
        this.loadOrgLimits();
        this._loadSavedQueries();
    }

    // ════════════════════════════════════════════════════════
    //  TAB
    // ════════════════════════════════════════════════════════
    handleTabChange(event) {
        const tab = event.detail.value;
        if (tab === 'objects' && !this.objectsLoaded) this.loadObjects();
        if (tab === 'limits'  && !Object.keys(this.orgLimits).length) this.loadOrgLimits();
    }

    // ════════════════════════════════════════════════════════
    //  SOQL EDITOR
    // ════════════════════════════════════════════════════════
    handleQueryInput(event) {
        this.query = event.target.value;
        this._triggerAC(event.target);
    }

    handleTextareaClick(event) {
        this._triggerAC(event.target);
    }

    handleKeydown(event) {
        if (this.acVisible) {
            if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
                event.preventDefault();
                this.acIndex = Math.min(this.acIndex + 1, this.acSuggestions.length - 1);
                this._refreshAcClasses();
                return;
            }
            if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
                event.preventDefault();
                this.acIndex = Math.max(this.acIndex - 1, -1);
                this._refreshAcClasses();
                return;
            }
            if (event.key === 'Escape') { this.acVisible = false; return; }
            if ((event.key === 'Enter' || event.key === 'Tab') && this.acIndex >= 0) {
                event.preventDefault();
                this._acceptSuggestion(this.acSuggestions[this.acIndex]);
                return;
            }
        }

        if (event.ctrlKey && event.key === 'Enter') {
            event.preventDefault();
            this.acVisible = false;
            this.runQuery();
            return;
        }
        if (event.key === 'Tab' && !this.acVisible) {
            event.preventDefault();
            const ta = event.target;
            const s  = ta.selectionStart;
            const e  = ta.selectionEnd;
            this.query = this.query.substring(0, s) + '    ' + this.query.substring(e);
            requestAnimationFrame(() => {
                const el = this.template.querySelector('.soql-textarea');
                if (el) { el.selectionStart = el.selectionEnd = s + 4; }
            });
        }
    }

    handleToolingToggle(event) {
        this.useToolingApi = event.target.checked;
        if (this.useToolingApi) this.useQueryAll = false;
    }

    handleQueryAllToggle(event) {
        this.useQueryAll = event.target.checked;
        if (this.useQueryAll) this.useToolingApi = false;
    }

    async runQuery() {
        if (!this.query.trim()) return;
        this.isLoading    = true;
        this.errorMessage = '';
        this.queryResult  = null;
        this.currentPage  = 1;
        this.resultFilter = '';
        this._sortCol     = '';
        this._sortAsc     = true;
        try {
            let result;
            if (this.useToolingApi) {
                result = await executeToolingQuery({ query: this.query.trim() });
            } else if (this.useQueryAll) {
                result = await executeQueryAll({ query: this.query.trim() });
            } else {
                result = await executeQuery({ query: this.query.trim() });
            }
            if (result.error) {
                this.errorMessage = result.error;
            } else {
                this.queryResult = result;
                this.columns     = this._orderedColumns(result.columns || [], this.query.trim());
                this.pushHistory(this.query.trim());
            }
        } catch (err) {
            this.errorMessage = err.body?.message || err.message || 'Unknown error';
        } finally {
            this.isLoading = false;
        }
    }

    clearQuery() {
        this.query        = '';
        this.queryResult  = null;
        this.errorMessage = '';
        this.columns      = [];
        this.acVisible    = false;
        this.resultFilter = '';
        this._sortCol     = '';
        this._sortAsc     = true;
        this._setTextareaValue('');
    }

    handleResultFilter(event) {
        this.resultFilter = event.detail.value;
        this.currentPage  = 1;
    }

    handleSortColumn(event) {
        const col = event.currentTarget.dataset.col;
        if (this._sortCol === col) {
            this._sortAsc = !this._sortAsc;
        } else {
            this._sortCol = col;
            this._sortAsc = true;
        }
    }

    _orderedColumns(serverCols, soql) {
        if (!serverCols.length) return serverCols;
        const parsed = this._parseColumnsFromSOQL(soql);
        if (!parsed || !parsed.length) return serverCols;
        const lower  = serverCols.map(c => c.toLowerCase());
        const used   = new Set();
        const ordered = [];
        for (const p of parsed) {
            const idx = lower.indexOf(p.toLowerCase());
            if (idx >= 0 && !used.has(idx)) {
                ordered.push(serverCols[idx]);
                used.add(idx);
            }
        }
        serverCols.forEach((c, i) => { if (!used.has(i)) ordered.push(c); });
        return ordered;
    }

    _parseColumnsFromSOQL(soql) {
        const m = /SELECT\s+([\s\S]+?)\s+FROM\b/i.exec(soql);
        if (!m) return null;
        const parts = [];
        let depth = 0, cur = '';
        for (const ch of m[1]) {
            if (ch === '(') { depth++; cur += ch; }
            else if (ch === ')') { depth--; cur += ch; }
            else if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; }
            else cur += ch;
        }
        if (cur.trim()) parts.push(cur.trim());
        return parts.map(p => {
            if (!p || p.startsWith('(')) return null;
            // Alias: e.g., COUNT(Id) total → 'total'
            const aliasM = /\)\s+(\w+)\s*$/i.exec(p);
            if (aliasM) return aliasM[1];
            // Aggregate without alias: COUNT(Id) → 'count'
            const fnM = /^(\w+)\s*\(/.exec(p);
            if (fnM) return fnM[1].toLowerCase();
            return p;
        }).filter(Boolean);
    }

    loadFromHistory(event) {
        this.query = event.target.value;
        event.target.value = '';
        this._setTextareaValue(this.query);
    }

    loadSavedQueryFromSelect(event) {
        const q = event.target.value;
        if (!q) return;
        this.query = q;
        event.target.value = '';
        this._setTextareaValue(this.query);
    }

    prevPage() { if (this.currentPage > 1) this.currentPage--; }
    nextPage()  { if (this.currentPage < this.totalPages) this.currentPage++; }

    // ── Export ─────────────────────────────────────────────────
    exportCSV()    { const r = this.filteredRows; if (!r.length) return; this._copyData(this._buildCSV(','),  `${r.length} rows copied as CSV`); }
    exportJSON()   { const r = this.filteredRows; if (!r.length) return; this._copyData(JSON.stringify(r, null, 2), `${r.length} rows copied as JSON`); }
    exportXLS()    { const r = this.filteredRows; if (!r.length) return; this._copyData(this._buildCSV('\t'), `${r.length} rows copied as Excel (TSV)`); }
    downloadCSV()  { const r = this.filteredRows; if (!r.length) return; this._downloadData(this._buildCSV(','),            'query_results.csv',  'text/csv'); }
    downloadJSON() { const r = this.filteredRows; if (!r.length) return; this._downloadData(JSON.stringify(r, null, 2),    'query_results.json', 'application/json'); }

    _buildCSV(sep) {
        const rows = this.filteredRows;
        if (!rows.length) return '';
        const hdr = this.columns.map(c => `"${c}"`).join(sep);
        const body = rows.map(r =>
            this.columns.map(c => {
                const v = r[c] == null ? '' : String(r[c]);
                return sep === '\t'
                    ? v.replace(/\t/g, ' ').replace(/\n/g, ' ')
                    : `"${v.replace(/"/g, '""')}"`;
            }).join(sep)
        );
        return [hdr, ...body].join('\r\n');
    }

    _copyData(text, successMsg) {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(text)
                .then(() => this.toast('Copied', successMsg, 'success'))
                .catch(() => this._fallbackCopy(text, successMsg));
        } else {
            this._fallbackCopy(text, successMsg);
        }
    }

    _fallbackCopy(text, successMsg) {
        try {
            const ta = document.createElement('textarea');
            ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
            document.body.appendChild(ta); ta.select();
            // eslint-disable-next-line @lwc/lwc/no-document-query
            document.execCommand('copy');
            document.body.removeChild(ta);
            this.toast('Copied', successMsg, 'success');
        } catch (e) {
            this.toast('Copy failed', 'Unable to copy to clipboard', 'error');
        }
    }

    _downloadData(text, filename, mime) {
        const blob = new Blob([text], { type: mime || 'text/plain' });
        const url  = URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href = url; a.download = filename;
        document.body.appendChild(a); a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    copyCell(event) { this.copyToClipboard(event.currentTarget.dataset.value); }

    // ════════════════════════════════════════════════════════
    //  SAVED QUERIES
    // ════════════════════════════════════════════════════════
    _loadSavedQueries() {
        try {
            const raw = localStorage.getItem('soqlEditor_savedQueries');
            this.savedQueriesList = raw ? JSON.parse(raw) : [];
        } catch (e) { this.savedQueriesList = []; }
    }

    _persistSavedQueries() {
        try { localStorage.setItem('soqlEditor_savedQueries', JSON.stringify(this.savedQueriesList)); } catch (e) { /* full */ }
    }

    toggleSaveInput() { this.showSaveInput = !this.showSaveInput; this.newQueryName = ''; }

    handleNewQueryName(event) { this.newQueryName = event.detail.value; }

    commitSaveQuery() {
        const name = this.newQueryName.trim();
        if (!name || !this.query.trim()) return;
        const entry = { id: Date.now().toString(), name, query: this.query.trim(), savedAt: new Date().toISOString() };
        const idx   = this.savedQueriesList.findIndex(q => q.name === name);
        if (idx >= 0) {
            this.savedQueriesList = [
                ...this.savedQueriesList.slice(0, idx), entry, ...this.savedQueriesList.slice(idx + 1)
            ];
        } else {
            this.savedQueriesList = [entry, ...this.savedQueriesList].slice(0, SAVED_MAX);
        }
        this._persistSavedQueries();
        this.showSaveInput = false;
        this.newQueryName  = '';
        this.toast('Saved', `"${name}" saved`, 'success');
    }

    deleteSavedQuery(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        this.savedQueriesList = this.savedQueriesList.filter(q => q.id !== id);
        this._persistSavedQueries();
    }

    // ════════════════════════════════════════════════════════
    //  AUTOCOMPLETE
    // ════════════════════════════════════════════════════════
    async _triggerAC(textarea) {
        const pos = textarea.selectionStart;
        const ctx = this._computeContext(this.query, pos);
        this._acContext = ctx;
        if (!ctx) { this.acVisible = false; return; }

        let suggestions = [];

        if (ctx.type === 'object') {
            const sourceList = this.useToolingApi ? TOOLING_OBJECTS : this.allObjects;
            if (!this.useToolingApi && !this.objectsLoaded) await this.loadObjects();
            const q = ctx.prefix.toLowerCase();
            suggestions = sourceList
                .filter(o => !q || o.apiName.toLowerCase().startsWith(q) || o.label.toLowerCase().includes(q))
                .slice(0, AC_LIMIT)
                .map(o => ({ value: o.apiName, label: o.apiName, meta: o.label }));

        } else if (ctx.type === 'field') {
            if (!ctx.objectName) { this.acVisible = false; return; }
            const fields = await this._getFieldsCached(ctx.objectName);
            const q = ctx.prefix.toLowerCase();
            suggestions = fields
                .filter(f => !q || f.apiName.toLowerCase().startsWith(q) || f.label.toLowerCase().includes(q))
                .slice(0, AC_LIMIT)
                .map(f => ({ value: f.apiName, label: f.apiName, meta: `${f.type}${f.referenceTo ? ' → '+f.referenceTo : ''}` }));

        } else if (ctx.type === 'relfield') {
            const relObj = await this._resolveRelObject(ctx.relPath, ctx.objectName);
            if (!relObj) { this.acVisible = false; return; }
            const fields = await this._getFieldsCached(relObj);
            const q = ctx.prefix.toLowerCase();
            suggestions = fields
                .filter(f => !q || f.apiName.toLowerCase().startsWith(q) || f.label.toLowerCase().includes(q))
                .slice(0, AC_LIMIT)
                .map(f => ({ value: ctx.relPath + '.' + f.apiName, label: f.apiName, meta: `${f.type} (${relObj})` }));

        } else if (ctx.type === 'value') {
            const q          = ctx.prefix.toLowerCase();
            const fieldParts = ctx.fieldChain.split('.');
            const fieldApi   = fieldParts[fieldParts.length - 1];
            let   fieldType  = null;

            if (ctx.objectName) {
                let objName = ctx.objectName;
                if (fieldParts.length > 1) {
                    objName = await this._resolveRelObject(fieldParts.slice(0, -1).join('.'), ctx.objectName) || objName;
                }
                const fields = await this._getFieldsCached(objName);
                const field  = fields.find(f => f.apiName.toLowerCase() === fieldApi.toLowerCase());
                if (field) fieldType = field.type;

                if (fieldType === 'PICKLIST' || fieldType === 'MULTIPICKLIST') {
                    const vals = await this._getPicklistValuesCached(objName, fieldApi);
                    suggestions = vals
                        .filter(v => !q || v.toLowerCase().includes(q))
                        .slice(0, AC_LIMIT)
                        .map(v => ({ value: `'${v}'`, label: v, meta: 'picklist' }));
                }
            }

            if (!suggestions.length) {
                if (fieldType === 'BOOLEAN') {
                    suggestions = ['true', 'false', 'null']
                        .filter(b => !q || b.startsWith(q))
                        .map(b => ({ value: b, label: b, meta: 'boolean' }));
                } else {
                    const pool = (fieldType === 'DATE' || fieldType === 'DATETIME' || !fieldType)
                        ? [...DATE_LITERALS, 'true', 'false', 'null']
                        : ['true', 'false', 'null'];
                    suggestions = pool
                        .filter(d => !q || d.toLowerCase().startsWith(q))
                        .slice(0, AC_LIMIT)
                        .map(d => ({ value: d, label: d, meta: /[_:]/.test(d) ? 'date literal' : 'constant' }));
                }
            }
        }

        if (!suggestions.length) { this.acVisible = false; return; }
        this.acIndex       = -1;
        this.acSuggestions = suggestions.map(s => ({ ...s, cls: 'ac-chip' }));
        this.acVisible     = true;
    }

    _computeContext(query, cursorPos) {
        const before      = query.substring(0, cursorPos);
        const wordMatch   = /[\w.]*$/.exec(before);
        const currentWord = wordMatch ? wordMatch[0] : '';
        const wordStart   = cursorPos - currentWord.length;
        const beforeWord  = before.substring(0, wordStart);

        // FROM <object>
        const fromCtx = /\bFROM\s+(\w*)$/i.exec(before);
        if (fromCtx) {
            return { type: 'object', prefix: fromCtx[1], wordStart: cursorPos - fromCtx[1].length };
        }

        // Effective main object — check subquery context first
        let mainObject = null;
        const subqueryCtx = /\(\s*SELECT\b[^()]*$/i.exec(before);
        if (subqueryCtx) {
            const innerFrom = /\bFROM\s+(\w+)/i.exec(subqueryCtx[0]);
            if (innerFrom) mainObject = innerFrom[1];
        }
        if (!mainObject) {
            const fromMatch = /\bFROM\s+(\w+)/i.exec(query);
            mainObject = fromMatch ? fromMatch[1] : null;
        }

        // Relationship traversal: Owner.Na
        if (currentWord.includes('.')) {
            const dotIdx  = currentWord.lastIndexOf('.');
            const relPath = currentWord.substring(0, dotIdx);
            const prefix  = currentWord.substring(dotIdx + 1);
            return { type: 'relfield', relPath, prefix, objectName: mainObject, wordStart };
        }

        // Value context: after comparison operator (includes optional opening quote)
        const valueCtx = /\b([\w.]+)\s*(?:=|!=|<>|<=|>=|<|>|LIKE)\s*('?\w*)$/i.exec(before);
        if (valueCtx) {
            const raw = valueCtx[2];
            return { type: 'value', fieldChain: valueCtx[1], prefix: raw.replace(/^'/, ''), objectName: mainObject, wordStart: cursorPos - raw.length };
        }

        // IN clause value context
        const inCtx = /\b([\w.]+)\s+(?:NOT\s+)?IN\s*\(\s*(?:'[^']*',\s*)*('?\w*)$/i.exec(before);
        if (inCtx) {
            const raw = inCtx[2];
            return { type: 'value', fieldChain: inCtx[1], prefix: raw.replace(/^'/, ''), objectName: mainObject, wordStart: cursorPos - raw.length };
        }

        // Field position: after SELECT, comma, WHERE, AND, OR, ORDER BY, GROUP BY, HAVING
        if (/(?:\bSELECT\b|\bWHERE\b|\bAND\b|\bOR\b|\bNOT\b|\bORDER\s+BY\b|\bGROUP\s+BY\b|\bHAVING\b|,)\s*$/i.test(beforeWord)) {
            return { type: 'field', objectName: mainObject, prefix: currentWord, wordStart };
        }

        return null;
    }

    async _resolveRelObject(relPath, mainObject) {
        if (!mainObject) return null;
        let current = mainObject;
        for (const part of relPath.split('.')) {
            const fields = await this._getFieldsCached(current);
            const lc     = part.toLowerCase();
            const field  = fields.find(f => {
                if (!f.referenceTo) return false;
                const a = f.apiName.toLowerCase();
                if (a.endsWith('id') && a.slice(0, -2) === lc) return true;
                if (a.endsWith('__c') && (a.slice(0, -3) + '__r') === lc) return true;
                return a === lc;
            });
            if (!field?.referenceTo) return null;
            current = field.referenceTo;
        }
        return current;
    }

    async _getFieldsCached(objectName) {
        const key = objectName.toLowerCase();
        if (!this._metaCache[key]) {
            try {
                const raw = await getFields({ objectApiName: objectName });
                this._metaCache[key] = raw.map(f => this.enrichField(f));
            } catch (e) { this._metaCache[key] = []; }
        }
        return this._metaCache[key];
    }

    async _getPicklistValuesCached(objectName, fieldApiName) {
        const key = `${objectName}__${fieldApiName}`.toLowerCase();
        if (!this._picklistCache[key]) {
            try { this._picklistCache[key] = await getPicklistValues({ objectApiName: objectName, fieldApiName }); }
            catch (e) { this._picklistCache[key] = []; }
        }
        return this._picklistCache[key];
    }

    _refreshAcClasses() {
        this.acSuggestions = this.acSuggestions.map((s, i) => ({
            ...s, cls: `ac-chip${this.acIndex === i ? ' ac-chip_active' : ''}`
        }));
    }

    _acceptSuggestion(sug) {
        if (!sug || !this._acContext) return;
        const ctx       = this._acContext;
        const ta        = this.template.querySelector('.soql-textarea');
        const cursorPos = ta ? ta.selectionStart : this.query.length;
        const after     = this.query.substring(cursorPos);
        this.query      = this.query.substring(0, ctx.wordStart) + sug.value + after;
        const newPos    = ctx.wordStart + sug.value.length;
        this.acVisible  = false;
        this._acContext = null;
        requestAnimationFrame(() => {
            const el = this.template.querySelector('.soql-textarea');
            if (el) { el.value = this.query; el.selectionStart = el.selectionEnd = newPos; el.focus(); }
        });
    }

    acSelect(event) {
        event.preventDefault();
        const val = event.currentTarget.dataset.value;
        const sug = this.acSuggestions.find(s => s.value === val);
        if (sug) this._acceptSuggestion(sug);
    }

    acHide() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.acVisible = false; }, 150);
    }

    // ════════════════════════════════════════════════════════
    //  OBJECT INSPECTOR
    // ════════════════════════════════════════════════════════
    async loadObjects() {
        if (this.objectsLoaded) return;
        this.isLoadingObjects = true;
        try {
            this.allObjects    = await getObjects();
            this.objectsLoaded = true;
        } catch (err) {
            this.toast('Error loading objects', err.body?.message || err.message, 'error');
        } finally { this.isLoadingObjects = false; }
    }

    handleObjectSearch(event) { this.objectSearch = event.detail.value; }
    handleFieldSearch(event)  { this.fieldSearch  = event.detail.value; }

    async selectObject(event) {
        const apiName        = event.currentTarget.dataset.apiName;
        this.selectedObject  = this.allObjects.find(o => o.apiName === apiName) || null;
        this.inspectorFields = [];
        this.fieldSearch     = '';
        if (!this.selectedObject) return;
        try {
            const raw = await getFields({ objectApiName: apiName });
            this.inspectorFields = raw.map(f => this.enrichField(f));
            this._metaCache[apiName.toLowerCase()] = this.inspectorFields;
        } catch (err) {
            this.toast('Error loading fields', err.body?.message || err.message, 'error');
        }
    }

    copySelectAll() {
        if (!this.selectedObject) return;
        const stmt = `SELECT ${this.inspectorFields.map(f => f.apiName).join(', ')}\nFROM ${this.selectedObject.apiName}`;
        this.copyToClipboard(stmt);
        this.toast('Copied', 'SELECT statement copied to clipboard', 'success');
    }

    copyText(event) { this.copyToClipboard(event.currentTarget.dataset.value); }

    // ════════════════════════════════════════════════════════
    //  RECORD INSPECTOR
    // ════════════════════════════════════════════════════════
    handleRecordIdChange(event)    { this.inspectRecordId   = event.detail.value; }
    handleRecordFieldSearch(event) { this.recordFieldSearch = event.detail.value; }

    handleRecordIdKeydown(event) { if (event.key === 'Enter') this.inspectRecord(); }

    async inspectRecord() {
        if (!this.inspectRecordId.trim()) { this.toast('Missing ID', 'Please enter a record ID', 'error'); return; }
        this.isLoadingRecord = true;
        this.recordFields    = null;
        this.editMode        = false;
        this.editValues      = {};
        try {
            const data = await getRecord({ recordId: this.inspectRecordId.trim() });
            if (data.error) { this.toast('Error', data.error, 'error'); return; }
            this.recordObjectType = data.__objectType__ || '';
            const meta = this.recordObjectType ? await getFields({ objectApiName: this.recordObjectType }) : [];
            const metaMap = {};
            meta.forEach(f => { metaMap[f.apiName] = f; });
            this.recordFieldMeta = metaMap;
            const fields = [];
            for (const [key, val] of Object.entries(data)) {
                if (key === '__objectType__') continue;
                const m = metaMap[key] || {};
                fields.push({
                    apiName:    key,
                    label:      m.label || key,
                    type:       m.type  || 'STRING',
                    displayVal: val == null ? '' : String(val),
                    typeBadge:  this.typeBadgeClass(m.type || 'STRING'),
                    updateable: m.updateable === true
                });
            }
            this.recordFields = fields;
        } catch (err) {
            this.toast('Error', err.body?.message || err.message, 'error');
        } finally { this.isLoadingRecord = false; }
    }

    handleEditMode() {
        const ev = {};
        (this.recordFields || []).forEach(f => { if (f.updateable) ev[f.apiName] = f.displayVal; });
        this.editValues = ev;
        this.editMode   = true;
    }

    cancelEdit() { this.editMode = false; this.editValues = {}; }

    handleFieldEdit(event) {
        const key = event.target.dataset.apiName;
        this.editValues = { ...this.editValues, [key]: event.target.value };
    }

    async saveRecord() {
        this.isLoadingRecord = true;
        try {
            const result = await updateRecord({ recordId: this.inspectRecordId.trim(), updatesJson: JSON.stringify(this.editValues) });
            if (result !== 'success') {
                this.toast('Save Failed', result, 'error');
            } else {
                this.toast('Saved', 'Record updated successfully', 'success');
                this.editMode = false; this.editValues = {};
                await this.inspectRecord();
            }
        } catch (err) {
            this.toast('Error', err.body?.message || err.message, 'error');
        } finally { this.isLoadingRecord = false; }
    }

    // ════════════════════════════════════════════════════════
    //  ORG LIMITS
    // ════════════════════════════════════════════════════════
    async loadOrgLimits() {
        this.isLoadingLimits = true;
        try { this.orgLimits = await getOrgLimits(); }
        catch (err) { this.toast('Error loading limits', err.body?.message || err.message, 'error'); }
        finally { this.isLoadingLimits = false; }
    }

    // ════════════════════════════════════════════════════════
    //  GETTERS — SOQL
    // ════════════════════════════════════════════════════════
    get containerClass()  { return `soql-wrap${this.utilityMode ? ' utility-mode' : ''}`; }
    get hasResults()      { return this.queryResult !== null; }
    get hasRows()         { return !!(this.queryResult?.rows?.length); }
    get showEmptyRows()   { return this.queryResult !== null && !this.hasRows; }
    get filteredRows() {
        const rows = this.queryResult?.rows || [];
        const q = (this.resultFilter || '').toLowerCase().trim();
        let result = q
            ? rows.filter(row =>
                  this.columns.some(col => {
                      const v = row[col];
                      return v != null && String(v).toLowerCase().includes(q);
                  })
              )
            : rows;
        if (this._sortCol) {
            const col = this._sortCol;
            const dir = this._sortAsc ? 1 : -1;
            result = [...result].sort((a, b) => {
                const av = a[col] == null ? '' : String(a[col]);
                const bv = b[col] == null ? '' : String(b[col]);
                return dir * av.localeCompare(bv, undefined, { numeric: true, sensitivity: 'base' });
            });
        }
        return result;
    }
    get resultSummary() {
        const total    = this.queryResult?.totalRows ?? 0;
        const filtered = this.filteredRows.length;
        if (this.resultFilter.trim() && filtered !== total) {
            return `${filtered} of ${total} record${total !== 1 ? 's' : ''} (filtered)`;
        }
        return `${total} record${total !== 1 ? 's' : ''} returned`;
    }
    get totalPages()      { return Math.max(1, Math.ceil(this.filteredRows.length / PAGE_SIZE)); }
    get isFirstPage()     { return this.currentPage <= 1; }
    get isLastPage()      { return this.currentPage >= this.totalPages; }
    get pageInfo()        { return `Page ${this.currentPage} of ${this.totalPages}`; }
    get hasHistory()      { return this._qh.length > 0; }
    get hasSavedQueries() { return this.savedQueriesList.length > 0; }

    get acBarLabel() {
        const ctx = this._acContext;
        if (!ctx) return 'Suggestions:';
        if (ctx.type === 'object')   return 'Object suggestions:';
        if (ctx.type === 'relfield') return `Fields on ${ctx.relPath}:`;
        if (ctx.type === 'value')    return `Values for ${ctx.fieldChain}:`;
        return ctx.objectName ? `Fields on ${ctx.objectName}:` : 'Field suggestions:';
    }

    get columnHeaders() {
        return this.columns.map(col => ({
            name:  col,
            label: col + (this._sortCol === col ? (this._sortAsc ? ' ▲' : ' ▼') : '')
        }));
    }

    get pagedRows() {
        const rows = this.filteredRows;
        const s = (this.currentPage - 1) * PAGE_SIZE;
        return rows.slice(s, s + PAGE_SIZE);
    }

    get processedRows() {
        return this.pagedRows.map((row, ri) => ({
            _key:  String(ri),
            cells: this.columns.map((col, ci) => ({ key: `${ri}-${ci}`, val: row[col] == null ? '' : String(row[col]) }))
        }));
    }

    get queryHistory() {
        return this._qh.map(q => ({ value: q, label: q.length > 80 ? q.substring(0, 80) + '…' : q }));
    }

    pushHistory(q) {
        this._qh = [q, ...this._qh.filter(h => h !== q)].slice(0, HISTORY_MAX);
    }

    // ════════════════════════════════════════════════════════
    //  GETTERS — OBJECT INSPECTOR
    // ════════════════════════════════════════════════════════
    get filteredObjects() {
        const q = (this.objectSearch || '').toLowerCase();
        return this.allObjects
            .filter(o => !q || o.apiName.toLowerCase().includes(q) || o.label.toLowerCase().includes(q))
            .map(o => ({ ...o, itemClass: `obj-item${this.selectedObject?.apiName === o.apiName ? ' obj-item_active' : ''}` }));
    }

    get filteredObjectCount() { return this.filteredObjects.length; }

    get filteredFields() {
        const q = (this.fieldSearch || '').toLowerCase();
        return this.inspectorFields.filter(f =>
            !q || f.apiName.toLowerCase().includes(q) || f.label.toLowerCase().includes(q) || f.type.toLowerCase().includes(q)
        );
    }

    get filteredFieldCount() { return this.filteredFields.length; }

    // ════════════════════════════════════════════════════════
    //  GETTERS — RECORD INSPECTOR
    // ════════════════════════════════════════════════════════
    get filteredRecordFields() {
        const q = (this.recordFieldSearch || '').toLowerCase();
        if (!this.recordFields) return [];
        return this.recordFields
            .filter(f => !q || f.apiName.toLowerCase().includes(q) || f.label.toLowerCase().includes(q) || f.displayVal.toLowerCase().includes(q))
            .map(f => ({
                ...f,
                editable: this.editMode && f.updateable,
                editVal:  this.editValues[f.apiName] !== undefined ? this.editValues[f.apiName] : f.displayVal
            }));
    }

    get recordUrl() { return `/${this.inspectRecordId}`; }

    // ════════════════════════════════════════════════════════
    //  GETTERS — ORG LIMITS
    // ════════════════════════════════════════════════════════
    get limitsArray() {
        return Object.entries(this.orgLimits)
            .map(([name, d]) => {
                const used  = d.used || 0;
                const max   = d.max  || 1;
                const pct   = max > 0 ? Math.round((used / max) * 100) : 0;
                const color = pct >= 90 ? 'red' : pct >= 70 ? 'yellow' : 'green';
                return {
                    name,
                    displayName: name.replace(/([A-Z])/g, ' $1').trim(),
                    used, max, pct,
                    pctLabel: `${pct}%`,
                    boxClass: `limit-box limit-${color}`,
                    barClass: `slds-progress-bar__value prog-${color}`,
                    barStyle: `width:${pct}%`
                };
            })
            .sort((a, b) => b.pct - a.pct);
    }

    // ════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════
    _setTextareaValue(val) {
        requestAnimationFrame(() => {
            const el = this.template.querySelector('.soql-textarea');
            if (el) el.value = val;
        });
    }

    enrichField(f) {
        return { ...f, required: !f.nillable, typeBadge: this.typeBadgeClass(f.type), lenDisplay: f.length > 0 ? String(f.length) : '' };
    }

    typeBadgeClass(type) {
        if (!type) return 'type-badge';
        return `type-badge type-${type.toLowerCase()}`;
    }

    copyToClipboard(text) {
        if (text == null || text === '') return;
        const str = String(text);
        if (navigator.clipboard) {
            navigator.clipboard.writeText(str)
                .then(() => this.toast('Copied', str.length > 60 ? str.substring(0, 60) + '…' : str, 'success'))
                .catch(() => this._fallbackCopy(str, str.length > 60 ? str.substring(0, 60) + '…' : str));
        } else {
            this._fallbackCopy(str, str.length > 60 ? str.substring(0, 60) + '…' : str);
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
