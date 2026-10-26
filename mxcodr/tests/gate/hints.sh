# tests/gate/hints.sh -- what a Mendix error code means, in one line each.
# Sourced by tests/gate.sh (for a failed boot) and by tests/precheck.sh (for the errors a
# script would add to the build). Functions only, no variables of its own: the two callers
# reach this file by different paths and neither has an app running when it does.
#
# A hint earns its place by having cost a session time. Keep them to one line, name the
# skill that has the syntax, and say the fix rather than the rule.

# Prints a hint for each CE code in <file>, once per code, in the order they appear.
mdl_ce_hints() {   # mdl_ce_hints <file>
  local code
  [ -f "$1" ] || return 0
  for code in $(grep -oE '\[CE[0-9]+\]' "$1" 2>/dev/null | tr -d '[]' | awk '!seen[$0]++'); do
    case "$code" in
      CE0161) echo "   hint CE0161 (XPath): tokens are quoted -- '[%CurrentUser%]', '[%CurrentDateTime%]' -- never CurrentUser() or \$currentUser; paths use full names (Module.Assoc/Module.Entity); a token compares only to a value of its type. Inside MDL's where '...' the quotes double and the ] stays inside them: ''[%CurrentUser%]'' (not ''[%CurrentUser%'']). Skill: xpath-constraints" ;;
      CE0117) echo "   hint CE0117 (expression): check each operand's type (a reference compares with = empty, a decimal does not fit an integer), function names, and enumeration values written Module.Enum.Value. The current time is the token [%CurrentDateTime%] (addDays([%CurrentDateTime%], -30)); now() and currentDateTime() do not exist. Skill: write-microflows" ;;
      CE1613) echo "   hint CE1613: a page or microflow names an attribute, association or document that does not exist (not created yet, or renamed) -- DESCRIBE the entity it points at"
              # Two sessions in a row: Name is System.User's, and Account only inherits it.
              if grep -q "CE1613.*'Administration\.Account\.Name'" "$1" 2>/dev/null; then
                echo "   hint CE1613 Administration.Account.Name: Name belongs to System.User and Account only inherits it -- show FullName (Account's own attribute), e.g. CaptionAttribute: FullName"
              fi
              # A local model went round this three times: an access rule path missing its entity step.
              if grep -q 'CE1613.*Access rule' "$1" 2>/dev/null; then
                echo "   hint CE1613 in an access rule: an XPath path alternates association and entity, ending on the association to the user, and the token is quoted whole: where '[Mod.Invoice_Customer/Mod.Customer/Mod.Customer_Account = ''[%CurrentUser%]'']' -- 'selected entity Mod.X_Y no longer exists' means an association stands where an entity step belongs. Skill: xpath-constraints"
              fi ;;
      # Three B2B runs in a row lost the OrderShipped publish and the AI agent call to this (2026-10-15):
      # mxcli 0.26 - 0.28 write a StringTemplate argument and an agent-document argument as plain expressions.
      CE0115)
        local known=""
        if grep -q "CE0115.*Java action 'BusinessEvents\.PublishBusinessEvent" "$1" 2>/dev/null; then known=1
          echo "   hint CE0115 BusinessEvents.PublishBusinessEvent_V2: its Subject is a text template, which mxcli cannot write yet -- do not drop the publish for a log line: call a small Java action of your own that publishes (pitfalls: 'A business event is published through a Java action of your own')"
        fi
        if grep -q "CE0115.*Java action 'AgentEditorCommons\.Agent_CallDocument" "$1" 2>/dev/null; then known=1
          echo "   hint CE0115 AgentEditorCommons.Agent_CallDocument_*: its Agent argument picks a document, which mxcli cannot write yet -- retrieve the agent object and call AgentCommons.Agent_Call_WithoutHistory(Agent = \$Agent, OptionalContextObject = \$Context) (pitfalls: 'An agent is called through AgentCommons')"
        fi
        if [ -z "$known" ]; then
          echo "   hint CE0115: the call's arguments do not match the action's parameters -- DESCRIBE the action and pass exactly its parameter names; a text-template or document parameter cannot be written by mxcli 0.26 - 0.28 (wrap the action in one of your own)"
        fi ;;
      CE0007) echo "   hint CE0007: an access rule names module roles of another module -- grant only this module's roles; for Administration.* give the user role Administration.User instead" ;;
      CE0642) echo "   hint CE0642: a required widget property is missing (a combo box or input needs a Caption/Label)" ;;
      CE2729) echo "   hint CE2729: a page reaches something a role that can open it may not use. First ask whether that role should open the page at all: a page meant for one role is opened by another through the navigation's single home page or a shared menu item -- give each role its own home in the navigation (home page Mod.Page for UserRole) and keep the page's view grant to its own role; never grant a role data it should not see to silence this. When the role does belong on the page, grant what the message names: 'grant execute on microflow Mod.DS_X to Mod.Role;' and 'grant read * on entity Mod.Entity to Mod.Role;' (a non-persistent entity behind a data view needs it too). Skill: manage-security"
              # 35-38 errors for one user role, page after page (b2b-orders hb4): a role created for a REST
              # client, and template roles with no role in the app's module, reach the pages through the
              # navigation -- the default home page and its snippets -- not through grants of their own.
              grep -E '\[CE2729\]' "$1" 2>/dev/null | sed -nE "s/.*for user role '([^']+)' \((with no roles defined in module '([^']+)'|with role)?.*/\1|\3/p" \
                | sort | uniq -c | awk '$1 >= 3' | while read -r count role_module; do
                    role="${role_module%%|*}"; module="${role_module#*|}"
                    if [ -n "$module" ]; then
                      echo "   hint CE2729 x$count for user role '$role': it has no module role of $module, so every page it reaches is refused -- give it one in the same script (alter user role \"$role\" add module roles (\"$module\".\"<Role>\");), or drop it and its demo user (drop demo user if exists '<name>'; drop user role if exists \"$role\";)"
                    else
                      echo "   hint CE2729 x$count for user role '$role': it reaches these pages through the navigation (the default home page when it has none of its own, and the menu). The script that creates a user role sets, in one go, its module roles, a page of its own and that page as its home: create user role \"$role\" (\"Mod\".\"$role\", \"System\".\"User\"); grant view on page Mod.${role}Home to Mod.$role; alter navigation Responsive { set home page Mod.${role}Home for \"$role\" }; (pitfalls: 'A new user role')"
                    fi
                  done ;;
      # Three sessions in a row: a page or microflow reached from a button, a menu or a page, with
      # no role. The pitfall "grant in the same script" was in the prompt each time; the name and
      # the line to paste, at the moment of the error, is what lands.
      CE0106|CE0557)
        if [ "$code" = "CE0106" ]; then
          echo "   hint CE0106: a microflow a page, a button or the menu uses needs a role -- in the script that creates it:"
        else
          echo "   hint CE0557: a page the menu, a button or a microflow opens needs a role -- in the script that creates it:"
        fi
        grep -E "\[$code\]" "$1" 2>/dev/null \
          | sed -nE -e "s/.* at ([A-Za-z0-9_]+) \/ (Microflow|Page) '([^'.]+)'.*/\2 \1.\3/p" \
                    -e "/ \/ (Microflow|Page) '/!s/.*(Microflow|Page) '([^']+)'.*/\1 \2/p" \
          | awk '!seen[$0]++' | head -6 | while read -r kind name; do
              case "$name" in *.*) ;; *) continue ;; esac
              if [ "$kind" = "Page" ]; then
                echo "     grant view on page $name to <each module role that opens it>;"
              else
                echo "     grant execute on microflow $name to <each module role whose page, button or menu calls it>;"
              fi
            done ;;
      # DeepSeek wrote `dropdown` for an enumeration; mx check refuses it for the React client. Checked
      # on Mendix 11.12: combobox and radiobuttons on the same attribute pass.
      CE0582) echo "   hint CE0582: the classic drop-down widget does not run in the React client -- for an enumeration or a Boolean write \`combobox cbStatus (Label: 'Status', Attribute: Status)\` (or radiobuttons) in its place. Skill: create-page" ;;
      # CE7247 is more than one error: a reserved name, and an invalid URL. A DeepSeek session set a
      # REST client's BaseUrl to a constant (stored as '{@Mod.Const}', refused as an invalid URL) and
      # was told to rename Owner/Type/Default. The hint follows the message, and says nothing when
      # it does not know the text. `get @Mod.Const + '/x'` is stored as that text (mxcli 0.28), so the
      # URL hint gives the template form.
      CE7247)
        if grep -q 'CE7247.*is a reserved word' "$1" 2>/dev/null; then
          echo "   hint CE7247: that name is reserved by the Mendix platform and quoting does not rescue it -- Owner, Type and Default have to be renamed (Staff, ResourceType, Standard); other keywords only need quotes. Full list: ./mxcli syntax keywords"
        fi
        if grep -q "CE7247.*URL '.*' is invalid" "$1" 2>/dev/null; then
          echo "   hint CE7247 (URL): a REST client's BaseUrl cannot take a constant in mxcli -- it is stored as '{@Mod.Const}' and refused -- and a written-in address is ENDPOINT01. Call the endpoint from the microflow and drop the client: create constant Mod.ApiBaseUrl ( Type: String, DefaultValue: 'https://api.example.com' ); then call rest service get '{1}/rates' with ({1} = @Mod.ApiBaseUrl) returns String;"
        fi ;;
    esac
  done
}
