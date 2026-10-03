"""The navigation menu: NAV01/NAV02 (a Log out item, last), NAV03 (every role's home page is
in the menu), NAV05 (an icon on every menu item) and NAV06 (no two entries one role sees share
an icon).

Part of check_layout.py; see its docstring for inputs and the full rule table.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field


# `create or replace navigation <Profile>` starts a profile's block in DESCRIBE NAVIGATION output.
PROFILE_RE = re.compile(r"^\s*create\s+(?:or\s+replace\s+)?navigation\s+(?P<name>\w+)", re.IGNORECASE)
# One `menu item '<caption>' ...;` line.
MENU_ITEM_RE = re.compile(r"^\s*menu\s+item\s+'(?P<caption>[^']*)'(?P<rest>.*)$", re.IGNORECASE)
SIGN_OUT_RE = re.compile(r"\bsign_out\b", re.IGNORECASE)


def menu_items(navigation: str) -> dict[str, list[tuple[str, bool]]]:
    """{profile: [(caption, is sign_out), ...]} in menu order; profiles without a menu are absent."""
    menus: dict[str, list[tuple[str, bool]]] = {}
    profile = ""
    for line in navigation.splitlines():
        found = PROFILE_RE.match(line)
        if found:
            profile = found.group("name")
            continue
        item = MENU_ITEM_RE.match(line)
        if item and profile:
            menus.setdefault(profile, []).append(
                (item.group("caption"), bool(SIGN_OUT_RE.search(item.group("rest")))))
    return menus


def sign_out_findings(navigation: str, other_mdl: str) -> tuple[list[dict], list[dict]]:
    """NAV01 / NAV02: an app whose users sign in needs a way to log out."""
    failures, warnings = [], []
    button_elsewhere = bool(SIGN_OUT_RE.search(other_mdl))
    for profile, items in sorted(menu_items(navigation).items()):
        signs_out = [index for index, (_caption, is_sign_out) in enumerate(items) if is_sign_out]
        if not signs_out:
            if not button_elsewhere:
                failures.append({
                    "check": "NAV01",
                    "line": 0,
                    "message": (f"navigation profile {profile}: users sign in, but its menu has no way to log"
                                f" out -- add `menu item 'Log out' sign_out icon Atlas_Core.Atlas_Filled.logout;`"
                                f" as the last menu item (DESCRIBE NAVIGATION {profile} first and keep the other items)"),
                })
        elif signs_out[-1] != len(items) - 1:
            warnings.append({
                "check": "NAV02",
                "line": 0,
                "message": f"navigation profile {profile}: the Log out item is not the last item of the menu",
            })
    return failures, warnings


# `home page Module.Page for Role` in DESCRIBE NAVIGATION output; the default home page has no `for`.
ROLE_HOME_RE = re.compile(r"^\s*home\s+page\s+(?P<page>[\w.]+)\s+for\s+(?P<role>[\w.]+)", re.IGNORECASE)
MENU_PAGE_RE = re.compile(r"^\s*menu\s+item\s+'[^']*'\s+page\s+(?P<page>[\w.]+)", re.IGNORECASE)

# The one-menu-for-every-role fact the NAV03/NAV04 messages carry, so the fix needs no lookup.
ONE_MENU = ("one menu serves every role: Mendix hides a menu item from a user who cannot open its page, so"
            " give each role its pages with `grant view on page` and list them all in the menu")


def role_home_findings(navigation: str) -> list[dict]:
    """NAV03: a role opens on a page its menu does not offer, so it cannot get back there."""
    failures = []
    homes: dict[str, list[tuple[str, str]]] = {}
    menu_pages: dict[str, set[str]] = {}
    profile = ""
    for line in navigation.splitlines():
        found = PROFILE_RE.match(line)
        if found:
            profile = found.group("name")
            continue
        home = ROLE_HOME_RE.match(line)
        if home and profile:
            homes.setdefault(profile, []).append((home.group("page"), home.group("role")))
        item = MENU_PAGE_RE.match(line)
        if item and profile:
            menu_pages.setdefault(profile, set()).add(item.group("page").lower())
    for profile, pairs in sorted(homes.items()):
        for page, role in pairs:
            if page.lower() in menu_pages.get(profile, set()):
                continue
            failures.append({
                "check": "NAV03",
                "line": 0,
                "message": (f"navigation profile {profile}: role {role} opens on {page}, which is not in the menu"
                            f" -- add `menu item '<caption>' page {page} icon <icon>;` before Log out"
                            f" (DESCRIBE NAVIGATION {profile} first and keep the other items); {ONE_MENU}"),
            })
    return failures


# A sub-menu line: `menu '<caption>' [icon ...] (`.
SUB_MENU_RE = re.compile(r"^\s*menu\s+'(?P<caption>[^']*)'(?P<rest>.*)$", re.IGNORECASE)
ICON_RE = re.compile(r"\bicon\b", re.IGNORECASE)
# Caption words -> an Atlas_Filled icon that shows the same thing; first match wins.
ICON_HINTS = (
    (("log out", "logout", "sign out"), "logout"),
    (("home", "start"), "home"),
    (("dashboard", "overview", "kpi"), "dashboard"),
    (("report", "analytic", "statistic", "chart"), "analytics-bars"),
    (("invoice", "bill"), "cash-payment-bill"),
    (("payment", "credit"), "credit-card"),
    (("order", "cart", "purchase"), "shopping-cart"),
    (("shipment", "delivery", "product", "stock"), "shipment-box"),
    (("my account", "profile"), "user"),
    # User management gets its own icon, so a Customers item next to it never shares one (NAV06).
    (("user", "account"), "user-neutral-shield"),
    (("customer", "client", "contact", "people", "employee"), "user-neutral-group"),
    (("task", "todo", "approval", "inbox"), "task-list-multiple"),
    (("document", "file", "contract"), "document"),
    (("calendar", "schedule", "planning"), "calendar"),
    (("mail", "message", "email"), "email"),
    (("setup", "setting", "config", "admin"), "cog"),
    (("search", "find"), "search"),
)


def suggested_icon(caption: str) -> str:
    low = caption.lower()
    for words, icon in ICON_HINTS:
        if any(word in low for word in words):
            return f'Atlas_Core.Atlas_Filled.{icon}' if "-" not in icon else f'Atlas_Core.Atlas_Filled."{icon}"'
    return ""


def menu_icon_findings(navigation: str) -> list[dict]:
    """NAV05: every menu entry carries an icon that shows what it opens."""
    failures = []
    profile = ""
    for line in navigation.splitlines():
        found = PROFILE_RE.match(line)
        if found:
            profile = found.group("name")
            continue
        entry = MENU_ITEM_RE.match(line) or SUB_MENU_RE.match(line)
        if not entry or not profile or ICON_RE.search(entry.group("rest")):
            continue
        caption = entry.group("caption")
        icon = suggested_icon(caption)
        fix = (f"`icon {icon}`" if icon else
               "an icon that shows what it opens, from `DESCRIBE ICON COLLECTION Atlas_Core.Atlas_Filled`")
        failures.append({
            "check": "NAV05",
            "line": 0,
            "message": (f"navigation profile {profile}: menu entry '{caption}' has no icon -- add {fix} at the end"
                        f" of its line; with the sidebar collapsed the icon is all a user sees"),
        })
    return failures


# --- NAV06: the entries one role sees never share an icon ------------------------------------

ICON_REF_RE = re.compile(r"\bicon\s+(?P<icon>[^;()]+?)\s*(?:;|\(|$)", re.IGNORECASE)
TARGET_RE = re.compile(r"\b(?P<kind>page|microflow)\s+(?P<name>[\w]+\.[\w]+)", re.IGNORECASE)
CLOSE_RE = re.compile(r"^\s*\)\s*;?\s*$")


@dataclass
class MenuEntry:
    caption: str
    icon: str            # normalised: no quotes, lower case; "" when there is none
    shown_icon: str      # as written, for the message
    target: str | None   # "page Mod.Page" / "microflow Mod.Flow"; None for sign_out, URL, sub-menu
    children: list["MenuEntry"] = field(default_factory=list)


def _icon(rest: str) -> tuple[str, str]:
    found = ICON_REF_RE.search(rest)
    if not found:
        return "", ""
    shown = found.group("icon").strip()
    return shown.replace('"', "").lower(), shown


def menu_entries(navigation: str) -> dict[str, list[MenuEntry]]:
    """{profile: every entry of its menu, sub-menus and the items inside them alike}."""
    menus: dict[str, list[MenuEntry]] = {}
    profile, stack = "", []
    for line in navigation.splitlines():
        found = PROFILE_RE.match(line)
        if found:
            profile, stack = found.group("name"), []
            continue
        if not profile:
            continue
        item = MENU_ITEM_RE.match(line)
        sub = None if item else SUB_MENU_RE.match(line)
        if item or sub:
            rest = (item or sub).group("rest")
            icon, shown = _icon(rest)
            target = TARGET_RE.search(rest) if item else None
            entry = MenuEntry((item or sub).group("caption"), icon, shown,
                              f"{target.group('kind').lower()} {target.group('name')}" if target else None)
            if stack:
                stack[-1].children.append(entry)
            menus.setdefault(profile, []).append(entry)
            if sub and rest.rstrip().endswith("("):
                stack.append(entry)
        elif CLOSE_RE.match(line) and stack:
            stack.pop()
    return menus


def read_menu_access(text: str) -> dict[str, set[str]]:
    """`<kind> <Mod.Name><TAB><SHOW ACCESS --json>` lines -> {"page Mod.Name": {"Mod.Role", ...}}.
    A target whose answer cannot be read is left out: it then counts as visible to every role."""
    access: dict[str, set[str]] = {}
    for line in text.splitlines():
        key, _, answer = line.partition("\t")
        try:
            rows = json.loads(answer)
        except ValueError:
            continue
        if isinstance(rows, list):
            kind, _, name = key.strip().partition(" ")
            access[f"{kind.lower()} {name.strip()}"] = {
                f"{row.get('Module', '')}.{row.get('Role', '')}" for row in rows if isinstance(row, dict)}
    return access


def _visible(entry: MenuEntry, module_roles: set[str], access: dict[str, set[str]] | None) -> bool:
    if entry.children:                       # a sub-menu shows when one of its items does
        return any(_visible(child, module_roles, access) for child in entry.children)
    if access is None or entry.target is None or entry.target not in access:
        return True                          # security off, sign_out, a URL, or access unknown
    return bool(access[entry.target] & module_roles)


def duplicate_icon_findings(navigation: str, roles: dict[str, set[str]],
                            access: dict[str, set[str]] | None) -> list[dict]:
    """NAV06: with the sidebar collapsed the icon is all a user sees, so the entries one user role
    sees -- Mendix hides those whose page or microflow the role may not open -- never share one.
    Without access (security off) everyone sees every entry."""
    viewers = roles if access is not None and roles else {"": set()}
    clashes: dict[tuple[str, str, str, str], list[str]] = {}
    for profile, entries in sorted(menu_entries(navigation).items()):
        for role, module_roles in sorted(viewers.items()):
            first: dict[str, MenuEntry] = {}
            for entry in entries:
                if not entry.icon or not _visible(entry, module_roles, access):
                    continue
                seen = first.setdefault(entry.icon, entry)
                if seen is not entry:
                    clashes.setdefault((profile, seen.caption, entry.caption, entry.shown_icon), []).append(role)
    failures = []
    for (profile, one, two, icon), who in sorted(clashes.items()):
        normal = icon.replace('"', "").lower()
        change, other = two, suggested_icon(two)
        if not other or other.replace('"', "").lower() == normal:
            change, other = one, suggested_icon(one)
        if other and other.replace('"', "").lower() != normal:
            fix = f"give '{change}' its own icon, e.g. `icon {other}`"
        else:
            fix = (f"give '{change}' its own icon, from `DESCRIBE ICON COLLECTION Atlas_Core.Atlas_Filled`")
        whom = "every user" if who == [""] else ("role " if len(who) == 1 else "roles ") + ", ".join(who)
        failures.append({
            "check": "NAV06",
            "line": 0,
            "message": (f"navigation profile {profile}: '{one}' and '{two}' both show icon {icon} for {whom}"
                        f" -- {fix} (DESCRIBE NAVIGATION {profile} first and keep the other items);"
                        f" with the sidebar collapsed the icon is all a user sees"),
        })
    return failures
