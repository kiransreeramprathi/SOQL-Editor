# SOQL Editor

A powerful, developer-focused Salesforce Lightning Web Component that brings a full query workbench, object browser, record inspector, and org limits dashboard into any Salesforce org — no AppExchange package required.

![SOQL Editor screenshot](https://github.com/user-attachments/assets/d1e50969-ee58-4f85-a871-1a8122df9a1f)

---

## Features

### SOQL Editor
- Dark-themed code editor with monospace font
- Run standard queries, **QueryAll** (includes soft-deleted records), or **Tooling API** queries
- **Ctrl+Enter** keyboard shortcut to run queries instantly
- **Tab** key inserts 4-space indentation in the editor
- Context-aware **autocomplete** — suggests objects, fields, relationship traversal (`Account.Owner.Name`), picklist values, date literals, and boolean constants as you type
- Results table with columns in the **exact order written in your SELECT clause**
- **Click any column header** to sort ascending/descending (▲/▼ indicator)
- **Click any cell** to copy its value to the clipboard
- Live **filter bar** to search across all result columns instantly
- Paginated results (50 rows per page)
- Export results as **CSV**, **JSON**, or **Excel (TSV)** — copy to clipboard or download as a file
- **Query history** dropdown (last 20 queries, session-scoped)
- **Saved queries** — name and save up to 50 queries, persisted in localStorage across sessions

### Object Inspector
- Searchable list of all SObjects in your org
- Field table showing API name, label, type (color-coded badge), length, required indicator, and reference target
- **Copy SELECT \*** — one-click to copy a full `SELECT field1, field2, ...` statement for any object
- Copy any individual field API name with one click
- Supports Tooling API objects (Apex classes, flows, metadata, etc.)

### Record Inspector
- Look up any record by 15- or 18-character Salesforce ID
- Displays all populated field values with their labels, API names, and data types
- **Edit mode** — inline editing of updateable fields with a single Save call
- Open the record in Salesforce with one click
- Filter fields by name, label, or value

### Org Limits
- Visual dashboard of all governor limits (API calls, SOQL queries, DML rows, etc.)
- Color-coded progress bars: green → yellow (70%) → red (90%)
- Sorted by usage percentage so the most critical limits appear first
- Refresh button to pull live data

---

## Screenshots

![Object Inspector](https://github.com/user-attachments/assets/1a8f53ca-f462-4c96-882b-37ea92a72173)
![Record Inspector](https://github.com/user-attachments/assets/3352cbb9-ea20-4bae-934f-b84d4f18ff6c)

---

## Installation

### Prerequisites
- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf` v2+)
- A Salesforce org (Developer Edition, sandbox, or scratch org)

### Deploy

```bash
# 1. Clone the repository
git clone https://github.com/kiransreeramprathi/SOQL-Editor.git
cd SOQL-Editor

# 2. Authenticate with your org
sf org login web --alias myorg

# 3. Deploy all metadata
sf project deploy start --source-dir force-app --target-org myorg --wait 10
```

### Add to Navigation

After deployment, add the **SOQL Editor** tab to your app or navigation bar via **Setup → App Manager** or from the App Launcher.

---

## Project Structure

```
force-app/main/default/
├── lwc/
│   └── soqlEditor/          # Main LWC component (JS, HTML, CSS)
├── classes/
│   ├── SoqlEditorController.cls       # Apex: execute queries, import records
│   ├── OrgMetadataController.cls      # Apex: objects, fields, limits, records
│   ├── SoqlEditorControllerTest.cls   # 100% coverage test class
│   └── OrgMetadataControllerTest.cls  # 100% coverage test class
├── flexipages/
│   └── SOQL_Editor.flexipage-meta.xml
├── tabs/
│   └── SOQL_Editor.tab-meta.xml
└── applications/
    └── SOQL_Editor.app-meta.xml
```

---

## Security

- All Apex controllers use `with sharing` — queries run in the context of the current user's permissions.
- Only `SELECT` statements are accepted by the query controller; DML through the editor is blocked.
- Record edits through the Record Inspector respect field-level security and object updateability.
- Tooling API calls use the current session token; no credentials are stored.

---

## Test Coverage

All Apex classes ship with test classes targeting **100% code coverage**:

| Class | Coverage |
|---|---|
| `SoqlEditorController` | 100% |
| `OrgMetadataController` | 100% |

Run tests:

```bash
sf apex run test --target-org myorg --code-coverage --result-format human
```

---

## License

MIT
