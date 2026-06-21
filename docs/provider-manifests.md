# Provider Manifests

Provider manifests are declarative HTTP integrations. A package is a folder with a `manifest.json` file that declares an endpoint, optional credentials, metric mappings, optional layout hints, optional default alerts, and optional commands.

Validate a package:

```bash
swift run ambit-check --validate-manifest Examples/provider-manifests/ping-demo
```

Run a package:

```bash
swift run ambit-check --run-manifest Examples/provider-manifests/secure-post-demo --manifest-credential api_token=value
```

## Credentials

Credentials are referenced with `{credential.<id>}` in endpoint URLs, headers, and bodies. Required credentials that are not configured produce a down provider snapshot with an actionable error.

```json
{
  "credentials": [
    { "id": "api_token", "label": "API Token", "kind": "bearerToken", "required": true }
  ],
  "endpoint": {
    "method": "POST",
    "url": "https://example.test/status",
    "headers": { "Authorization": "Bearer {credential.api_token}" },
    "body": "{\"query\":\"status\"}"
  }
}
```

## Metrics And Transforms

Metrics map JSON paths into Ambit metric values. Transforms run before type conversion.

```json
{
  "id": "battery_percent",
  "label": "Battery",
  "value": {
    "type": "percent",
    "path": "battery_ratio",
    "transforms": [
      { "type": "multiply", "value": 100 },
      { "type": "round" }
    ]
  }
}
```

Supported transforms: `multiply`, `divide`, `round`, `clamp`, and `defaultValue`.

## Layout

Layout hints are surface-agnostic metadata. Menubar, widgets, island, notifications, and future app windows can choose how much to honor them.

```json
{
  "layout": {
    "icon": "bolt",
    "accent": "green",
    "primaryMetric": "battery_percent"
  }
}
```

## Alerts

Manifest alerts compile into core `AlertRule` values. Threshold alerts compare numeric metrics.

```json
{
  "alerts": [
    {
      "id": "battery.low",
      "metricID": "battery_percent",
      "kind": { "type": "threshold", "comparison": "lessThan", "value": 20 },
      "title": "Power Demo battery low",
      "message": "Power Demo battery is below 20%.",
      "severity": "warning"
    }
  ]
}
```
