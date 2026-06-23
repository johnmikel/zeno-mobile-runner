# iOS Shim Protocol

The iOS shim protocol is internal and may change before `v1.0.0`.

Commands are newline-delimited JSON objects:

```json
{"cmd":"snapshot"}
{"cmd":"viewport"}
{"cmd":"tap","selector":"text=Continue","x":20,"y":40}
{"cmd":"type","selector":"identifier=email","text":"hello"}
{"cmd":"eraseText","selector":"identifier=email","maxChars":20}
{"cmd":"hideKeyboard"}
{"cmd":"swipe","x1":300,"y1":900,"x2":300,"y2":300,"durationMs":250}
{"cmd":"pressBack"}
{"cmd":"settle","durationMs":1000}
{"cmd":"appState"}
{"cmd":"acceptSystemAlert","text":"Open"}
{"cmd":"query","selector":"textContains=Continue"}
{"cmd":"screenshot"}
```

Selector-addressed `tap`, `type`, and `eraseText` support these internal
selector strings:

- `text=<exact>` and `textContains=<substring>`
- `label=<exact>` and `labelContains=<substring>`
- `identifier=<exact>` and `identifierContains=<substring>`
- `resourceId=<exact>` and `resourceIdContains=<substring>`
- `id=<stable snapshot id>`
- `value=<exact>` and `valueContains=<substring>`
- `type=<XCUIElementType...>`

`query` is the fast path used by Zig waits/assertions for single-field selectors
that XCTest can evaluate natively. It returns:

```json
{"status":"ok","exists":true,"hittable":true}
```

`screenshot` returns a PNG payload encoded for the local shim transport:

```json
{"status":"ok","format":"png","base64":"..."}
```

`viewport` returns the target application frame in XCTest point coordinates
without crawling the element hierarchy:

```json
{"status":"ok","viewport":{"width":390,"height":844}}
```

Snapshot responses return bounded XCTest element data in a shape Zig can map
into `UiNode`. The shim captures common interactive and readable element
families and caps the response at 256 nodes so large application trees do not
turn every snapshot into a full hierarchy crawl:

```json
{
  "status": "ok",
  "viewport": { "width": 390, "height": 844 },
  "nodes": [
    {
      "id": "button-continue",
      "type": "XCUIElementTypeButton",
      "label": "Continue",
      "value": "Continue",
      "identifier": "continue_button",
      "bounds": { "x": 10, "y": 20, "width": 100, "height": 44 },
      "enabled": true,
      "visible": true,
      "selected": false
    }
  ]
}
```

Errors use a stable envelope:

```json
{"status":"error","code":"selector.timeout","message":"selector did not match"}
```
