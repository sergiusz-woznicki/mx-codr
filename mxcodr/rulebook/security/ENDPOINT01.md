---
step: security
level: block
check: security_rules.cjs#endpoint01
key: document
---

# ENDPOINT01 — every REST address comes from a constant

## What it checks
No consumed REST service and no REST call action in a microflow has its address (http(s):// and a host) written in. A written-in address, often localhost and a port, calls the wrong place on any other port and in every deployment; a constant is set per environment. This holds for the app's own published service too. A URL whose host comes from a template parameter passes; Marketplace modules are not checked. A constant through which the app calls itself (its own published REST service, or the port the gate runs it on) names the model's own port, the HttpPortNumber of its configuration: the gate runs the app on another port and its boot points such a constant there (read at boot: `bash tests/gate.sh --restart` once after changing it), so a constant on the gate's port works in the tests and calls nothing from Studio Pro or a deployment.

## Fix
`create constant Mod.ApiBaseUrl ( Type: String, DefaultValue: 'https://api.example.com' );` then `call rest service get '{1}/forecast' with ({1} = @Mod.ApiBaseUrl) returns String;`. A REST client's BaseUrl cannot take a constant in mxcli (CE7247): call from the microflow and drop the client. `get @Mod.ApiBaseUrl + '/x'` is stored as that text. The app's own service: `DefaultValue: 'http://localhost:<HttpPortNumber>'` (`show settings` prints it as `http=`); the runtime's own root URL is not a way out (empty under `mxcli test`, not derived from the port).

## Local
# level: block
# except: Module.Document   # why
