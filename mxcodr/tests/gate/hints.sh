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
      CE0007) echo "   hint CE0007: an access rule names module roles of another module -- grant only this module's roles; for Administration.* give the user role Administration.User instead" ;;
      CE0642) echo "   hint CE0642: a required widget property is missing (a combo box or input needs a Caption/Label)" ;;
      CE2729) echo "   hint CE2729: a page reaches something its viewers may not use. The message names both halves -- grant the microflow to that role and the entity it returns: 'grant execute on microflow Mod.DS_X to Mod.Role;' and 'grant Mod.Role on Mod.Entity (read *);'. A non-persistent entity behind a data view needs the grant as much as a stored one, and every role that can open the page needs it. Skill: manage-security" ;;
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
      # it does not know the text.
      CE7247)
        if grep -q 'CE7247.*is a reserved word' "$1" 2>/dev/null; then
          echo "   hint CE7247: that name is reserved by the Mendix platform and quoting does not rescue it -- Owner, Type and Default have to be renamed (Staff, ResourceType, Standard); other keywords only need quotes. Full list: ./mxcli syntax keywords"
        fi
        if grep -q "CE7247.*URL '.*' is invalid" "$1" 2>/dev/null; then
          echo "   hint CE7247 (URL): a REST client's BaseUrl must be a literal http:// or https:// address -- a constant there is stored as '{@Mod.Const}' and refused. To point the app at a mock, build the URL in the microflow instead (rest call get @Mod.ApiBaseUrl + '/rates') or change the literal. Skill: mock-rest-apis"
        fi ;;
    esac
  done
}
