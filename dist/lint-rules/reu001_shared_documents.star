# REU001: Shared Documents
#
# The reuse-and-snippets rules that the model can actually answer:
#   - a snippet exists to be used more than once
#   - a SUB_ microflow with fewer than two callers is an extra hop, not reuse
#
# Both are reference counts, so this is the Starlark twin of the reuse half of
# tests/skills/check_mdl.py. Requires FULL catalog for refs_to(); mxcli lint
# detects that and builds it automatically.

RULE_ID = "REU001"
RULE_NAME = "SharedDocuments"
DESCRIPTION = "A snippet is used on more than one page, and a SUB_ microflow has more than one caller"
CATEGORY = "architecture"
SEVERITY = "info"

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
]

# Reference kinds that mean "something runs this microflow".
CALL_KINDS = ["call", "schedule", "datasource", "action", "calculate"]

def distinct_sources(references, kinds):
    """How many different documents reference the target in one of these ways."""
    sources = {}
    for reference in references:
        if kinds == None or reference.ref_kind in kinds:
            sources[reference.source_name] = True
    return len(sources)

def check():
    violations = []

    for snippet in snippets():
        if snippet.module_name in SKIP_MODULES:
            continue

        users = distinct_sources(refs_to(snippet.qualified_name), None)
        if users < 2:
            violations.append(violation(
                message = "snippet '%s' is used by %d page(s) — a snippet that is not shared is just a page section" % (snippet.name, users),
                location = location(
                    module = snippet.module_name,
                    document_type = "Snippet",
                    document_name = snippet.qualified_name,
                ),
                suggestion = "use it on a second screen, or inline it back into the page that needs it",
            ))

    for flow in microflows():
        if flow.module_name in SKIP_MODULES:
            continue
        if not flow.name.startswith("SUB_"):
            continue

        callers = distinct_sources(refs_to(flow.qualified_name), CALL_KINDS)
        if callers < 2:
            violations.append(violation(
                message = "SUB_ microflow '%s' has %d caller(s) — extraction pays off from the second" % (flow.name, callers),
                location = location(
                    module = flow.module_name,
                    document_type = "Microflow",
                    document_name = flow.qualified_name,
                ),
                suggestion = "call it from the second place that needs the step, or inline it into its only caller",
            ))

    return violations
