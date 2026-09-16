# MOD001: every document sits in a process-named folder, not at module root or in a type folder (any path segment).
# Loaded by `mxcli lint` from .claude/lint-rules; warnings only, the gate does not fail on them.

RULE_ID = "MOD001"
RULE_NAME = "ProcessFolders"
DESCRIPTION = "Documents live in process-named folders, never at module root or in type folders"
CATEGORY = "architecture"
SEVERITY = "warning"

# Type folders split a process; the ACT_/SUB_/DS_/VAL_ prefixes already give the type.
TYPE_FOLDER_NAMES = [
    "microflows",
    "nanoflows",
    "pages",
    "snippets",
    "logic",
    "ui",
    "flows",
    "screens",
    "forms",
    "layouts",
    "rules",
    "javaactions",
]

# Mendix and Marketplace modules.
SKIP_MODULES = [
    "System",
    "Atlas_Core",
    "Atlas_Web_Content",
    "Atlas_UI_Resources",
    "DataWidgets",
    "FeedbackModule",
    "NanoflowCommons",
    "WebActions",
    "Administration",
    "MyFirstModule",
]

def is_type_folder(folder):
    """True when any segment of the path names a document type."""
    for segment in folder.split("/"):
        if segment.strip().lower() in TYPE_FOLDER_NAMES:
            return True
    return False

# kind: label for messages ("Microflow", "Page", "Snippet").
def check_documents(documents, kind, violations):
    for document in documents:
        if document.module_name in SKIP_MODULES:
            continue

        folder = document.folder.strip()

        if folder == "":
            violations.append(violation(
                message = "%s '%s' sits at module root instead of a process folder" % (kind, document.name),
                location = location(
                    module = document.module_name,
                    document_type = kind,
                    document_name = document.qualified_name,
                ),
                suggestion = "move %s to a folder named for the process it serves" % document.name,
            ))
        elif is_type_folder(folder):
            violations.append(violation(
                message = "%s '%s' is in '%s', a folder named after a document type" % (kind, document.name, folder),
                location = location(
                    module = document.module_name,
                    document_type = kind,
                    document_name = document.qualified_name,
                ),
                suggestion = "name the folder for the business process, not the document type",
            ))

def check():
    violations = []
    check_documents(microflows(), "Microflow", violations)
    check_documents(pages(), "Page", violations)
    check_documents(snippets(), "Snippet", violations)
    return violations
