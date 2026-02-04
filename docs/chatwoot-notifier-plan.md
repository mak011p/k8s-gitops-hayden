# Chatwoot Notifier - Implementation Plan

## Overview

A sidecar service that bridges Chatwoot and Odoo to provide SLA breach notifications and cross-platform alerts.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           CLUSTER (business-system)                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐                    ┌──────────────────────────┐  │
│  │     Chatwoot     │                    │    chatwoot-notifier     │  │
│  │                  │   POST /webhook    │                          │  │
│  │  conversation_   │ ────────────────▶  │  1. Receive webhook      │  │
│  │  created/updated │                    │  2. Check SLA status     │  │
│  │                  │ ◀──────────────── │  3. Evaluate breach      │  │
│  │                  │   GET /api/v1/...  │  4. Send notifications   │  │
│  └──────────────────┘                    └───────────┬──────────────┘  │
│         :3000                                        │ :5000           │
│                                                      │                 │
│                          ┌───────────────────────────┼────────┐        │
│                          │                           │        │        │
│                          ▼                           ▼        ▼        │
│                   ┌─────────────┐            ┌───────────┐ ┌──────┐   │
│                   │    Odoo     │            │   SMTP    │ │Slack │   │
│                   │             │            │  Server   │ │ API  │   │
│                   │ XML-RPC API │            └───────────┘ └──────┘   │
│                   │ :8071       │                                      │
│                   │             │                                      │
│                   │ • Activity  │                                      │
│                   │ • Chatter   │                                      │
│                   │ • Bus notif │                                      │
│                   └─────────────┘                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Webhook Receiver
- Flask/FastAPI endpoint receiving Chatwoot webhooks
- Events: `conversation_created`, `conversation_updated`, `message_created`
- Validates webhook signature (if configured)

### 2. SLA Monitor
- Polls Chatwoot API for conversation SLA status
- Tracks `applied_sla` and `sla_events` from conversation details
- Calculates time-to-breach for FRT/NRT thresholds

### 3. Notification Dispatcher
- Email via SMTP (existing cluster SMTP config)
- Odoo activities via XML-RPC
- Optional: Slack webhook

---

## Chatwoot Integration

### Webhook Events to Subscribe

| Event | Use Case |
|-------|----------|
| `conversation_created` | Start SLA tracking |
| `conversation_updated` | Check for SLA changes, assignee changes |
| `message_created` | Reset NRT timer on customer message |

### Webhook Payload (conversation_updated)

```json
{
  "event": "conversation_updated",
  "id": 123,
  "account": {
    "id": 1,
    "name": "Hayden Agencies"
  },
  "changed_attributes": {
    "sla_policy_id": {
      "previous_value": null,
      "current_value": 1
    }
  },
  "meta": {
    "assignee": {
      "id": 2,
      "name": "Anita Karisson",
      "email": "anita@haydenagencies.com.au"
    },
    "team": {
      "id": 1,
      "name": "customer service"
    }
  },
  "sla_policy_id": 1
}
```

### API Endpoints Required

| Endpoint | Purpose |
|----------|---------|
| `GET /api/v1/accounts/{id}/conversations/{id}` | Get full conversation with `applied_sla`, `sla_events` |
| `GET /api/v1/accounts/{id}/sla_policies` | List SLA policies with thresholds |
| `GET /api/v1/accounts/{id}/agents` | Get agent list for user mapping |

### API Response - Conversation Details

```json
{
  "id": 123,
  "status": "open",
  "assignee_id": 2,
  "team_id": 1,
  "sla_policy_id": 1,
  "applied_sla": {
    "id": 1,
    "sla_status": "active",
    "created_at": "2026-02-04T09:00:00Z"
  },
  "sla_events": [
    {
      "event_type": "frt_breach",
      "created_at": "2026-02-04T09:05:30Z",
      "meta": {}
    }
  ]
}
```

### SLA Event Types

| Event Type | Meaning |
|------------|---------|
| `frt` | First Response Time tracking started |
| `frt_breach` | FRT threshold exceeded |
| `nrt` | Next Response Time tracking started |
| `nrt_breach` | NRT threshold exceeded |
| `rt` | Resolution Time tracking started |
| `rt_breach` | Resolution Time exceeded |

---

## Odoo Integration

### Connection Details

```yaml
host: odoo.business-system.svc.cluster.local
port: 8071  # XML-RPC port
database: odoo  # from secret odoo-pg-app
```

### Authentication

```python
import xmlrpc.client

url = "http://odoo.business-system.svc.cluster.local:8071"
db = "odoo"
username = "admin"  # or API user
password = "..."    # from secret

# Authenticate
common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common")
uid = common.authenticate(db, username, password, {})

# Object proxy for API calls
models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")
```

### Creating Activities

```python
# Get model ID for res.partner (or res.users)
model_id = models.execute_kw(
    db, uid, password,
    'ir.model', 'search',
    [[['model', '=', 'res.partner']]]
)[0]

# Find Odoo user by email
user_ids = models.execute_kw(
    db, uid, password,
    'res.users', 'search',
    [[['email', '=', 'skye@haydenagencies.com.au']]]
)

# Create activity (appears in user's activity panel)
activity_id = models.execute_kw(
    db, uid, password,
    'mail.activity', 'create',
    [{
        'activity_type_id': 4,  # To-Do type
        'summary': 'Chatwoot SLA Breach Alert',
        'note': '<p>Conversation #123 has breached FRT SLA (5 min)</p>',
        'date_deadline': '2026-02-04',
        'user_id': user_ids[0],
        'res_model_id': model_id,
        'res_id': user_ids[0],  # Link to user's partner record
    }]
)
```

### Sending Notifications (Chatter)

```python
# Post message to a record (appears in chatter)
models.execute_kw(
    db, uid, password,
    'res.users', 'message_post',
    [user_ids],
    {
        'body': '<p><strong>SLA Breach Alert</strong></p><p>Conversation #123 breached FRT</p>',
        'message_type': 'notification',
        'subtype_xmlid': 'mail.mt_note',
    }
)
```

### Bus Notification (Popup Toast)

```python
# Send instant notification (requires longpolling connection)
models.execute_kw(
    db, uid, password,
    'bus.bus', '_sendone',
    [
        f'res.partner_{partner_id}',  # Channel
        'simple_notification',
        {
            'title': 'SLA Breach',
            'message': 'Conversation #123 breached FRT threshold',
            'sticky': True,
            'type': 'warning',
        }
    ]
)
```

---

## User Mapping

### Strategy: Email-based matching

Both Chatwoot and Odoo use email as unique identifier.

```yaml
# ConfigMap: chatwoot-notifier-config
user_mappings:
  # Chatwoot email -> notification preferences
  anita@haydenagencies.com.au:
    odoo_notify: true
    email_notify: true
    teams: [customer_service]

  dearne@haydenagencies.com.au:
    odoo_notify: true
    email_notify: true
    teams: [customer_service]

  skye@haydenagencies.com.au:
    odoo_notify: true
    email_notify: true
    teams: [management]

  ashleigh@haydenagencies.com.au:
    odoo_notify: true
    email_notify: true
    teams: [management]

  mehreen@haydenagencies.com.au:
    odoo_notify: true
    email_notify: true
    teams: [management]

  thomas@haydenagencies.com.au:
    odoo_notify: false
    email_notify: false
    teams: [owner]

  isabelle@haydenagencies.com.au:
    odoo_notify: false
    email_notify: false
    teams: [owner]
```

---

## Notification Logic

### Trigger Conditions

```python
NOTIFICATION_RULES = [
    {
        "name": "SLA FRT Breach",
        "condition": lambda conv: "frt_breach" in [e["event_type"] for e in conv.get("sla_events", [])],
        "notify_teams": ["management"],
        "channels": ["email", "odoo_activity"],
        "message": "Conversation #{id} breached First Response Time SLA ({threshold})"
    },
    {
        "name": "SLA NRT Breach",
        "condition": lambda conv: "nrt_breach" in [e["event_type"] for e in conv.get("sla_events", [])],
        "notify_teams": ["management"],
        "channels": ["email", "odoo_activity"],
        "message": "Conversation #{id} breached Next Response Time SLA ({threshold})"
    },
    {
        "name": "Unassigned Conversation Warning",
        "condition": lambda conv: conv.get("assignee_id") is None and conv.get("status") == "open",
        "notify_teams": ["management"],
        "channels": ["odoo_activity"],
        "message": "Conversation #{id} is unassigned"
    },
]
```

### Deduplication

Track sent notifications to avoid spam:

```python
# Redis or in-memory cache
notification_cache = {}

def should_notify(conversation_id: int, event_type: str) -> bool:
    key = f"{conversation_id}:{event_type}"
    if key in notification_cache:
        return False
    notification_cache[key] = datetime.now()
    return True
```

---

## Kubernetes Deployment

### Directory Structure

```
kubernetes/apps/base/business-system/chatwoot-notifier/
├── ks.yaml                          # Flux Kustomization
└── app/
    ├── kustomization.yaml
    ├── deployment.yaml              # Or helmrelease.yaml with app-template
    ├── service.yaml
    ├── configmap.yaml               # User mappings, notification rules
    ├── secret.enc.age.yaml          # API keys, credentials
    └── networkpolicy.yaml           # Allow Chatwoot, Odoo, SMTP
```

### Deployment Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-notifier
  namespace: business-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: chatwoot-notifier
  template:
    metadata:
      labels:
        app.kubernetes.io/name: chatwoot-notifier
    spec:
      containers:
        - name: notifier
          image: ghcr.io/hayden-agencies/chatwoot-notifier:latest
          ports:
            - containerPort: 5000
          env:
            - name: CHATWOOT_URL
              value: "http://chatwoot-web.business-system.svc.cluster.local:3000"
            - name: CHATWOOT_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: chatwoot-notifier
                  key: chatwoot-api-token
            - name: ODOO_URL
              value: "http://odoo.business-system.svc.cluster.local:8071"
            - name: ODOO_DB
              valueFrom:
                secretKeyRef:
                  name: odoo-pg-app
                  key: dbname
            - name: ODOO_USER
              valueFrom:
                secretKeyRef:
                  name: chatwoot-notifier
                  key: odoo-user
            - name: ODOO_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: chatwoot-notifier
                  key: odoo-password
            - name: SMTP_HOST
              value: "smtp.gmail.com"
            - name: SMTP_PORT
              value: "587"
          volumeMounts:
            - name: config
              mountPath: /app/config
      volumes:
        - name: config
          configMap:
            name: chatwoot-notifier-config
```

### NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chatwoot-notifier
  namespace: business-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: chatwoot-notifier
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow webhooks from Chatwoot
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: chatwoot
      ports:
        - port: 5000
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
    # Chatwoot API
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: chatwoot
      ports:
        - port: 3000
    # Odoo XML-RPC
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: odoo
      ports:
        - port: 8071
    # SMTP
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - port: 587
        - port: 465
```

---

## Application Code Structure

```
chatwoot-notifier/
├── Dockerfile
├── requirements.txt
├── app/
│   ├── __init__.py
│   ├── main.py              # Flask app entry point
│   ├── config.py            # Configuration management
│   ├── webhooks/
│   │   ├── __init__.py
│   │   └── chatwoot.py      # Webhook handlers
│   ├── clients/
│   │   ├── __init__.py
│   │   ├── chatwoot.py      # Chatwoot API client
│   │   └── odoo.py          # Odoo XML-RPC client
│   ├── notifications/
│   │   ├── __init__.py
│   │   ├── dispatcher.py    # Notification routing
│   │   ├── email.py         # Email sender
│   │   └── odoo.py          # Odoo notification sender
│   └── sla/
│       ├── __init__.py
│       └── monitor.py       # SLA breach detection
└── tests/
    └── ...
```

### Main Application (main.py)

```python
from flask import Flask, request, jsonify
from app.webhooks.chatwoot import handle_webhook
from app.config import Config

app = Flask(__name__)
config = Config()

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"})

@app.route('/webhook/chatwoot', methods=['POST'])
def chatwoot_webhook():
    payload = request.json
    result = handle_webhook(payload, config)
    return jsonify(result)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
```

### Chatwoot Webhook Handler

```python
from app.clients.chatwoot import ChatwootClient
from app.notifications.dispatcher import NotificationDispatcher
from app.sla.monitor import check_sla_breach

def handle_webhook(payload: dict, config) -> dict:
    event = payload.get('event')

    if event == 'conversation_created':
        # New conversation - start monitoring
        return {"status": "received", "action": "monitoring_started"}

    elif event == 'conversation_updated':
        conversation_id = payload.get('id')
        account_id = payload.get('account', {}).get('id')

        # Fetch full conversation with SLA details
        client = ChatwootClient(config.chatwoot_url, config.chatwoot_token)
        conversation = client.get_conversation(account_id, conversation_id)

        # Check for SLA breaches
        breaches = check_sla_breach(conversation)

        if breaches:
            dispatcher = NotificationDispatcher(config)
            for breach in breaches:
                dispatcher.notify(breach, conversation)

        return {"status": "processed", "breaches": len(breaches)}

    return {"status": "ignored"}
```

### Odoo Notification Client

```python
import xmlrpc.client
from typing import Optional

class OdooClient:
    def __init__(self, url: str, db: str, username: str, password: str):
        self.url = url
        self.db = db
        self.username = username
        self.password = password
        self._uid = None
        self._models = None

    def connect(self):
        common = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/common")
        self._uid = common.authenticate(self.db, self.username, self.password, {})
        self._models = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/object")
        return self._uid is not None

    def get_user_by_email(self, email: str) -> Optional[int]:
        user_ids = self._models.execute_kw(
            self.db, self._uid, self.password,
            'res.users', 'search',
            [[['email', '=', email]]]
        )
        return user_ids[0] if user_ids else None

    def create_activity(self, user_id: int, summary: str, note: str):
        # Get partner model ID
        model_id = self._models.execute_kw(
            self.db, self._uid, self.password,
            'ir.model', 'search',
            [[['model', '=', 'res.users']]]
        )[0]

        return self._models.execute_kw(
            self.db, self._uid, self.password,
            'mail.activity', 'create',
            [{
                'activity_type_id': 4,  # To-Do
                'summary': summary,
                'note': note,
                'date_deadline': datetime.now().strftime('%Y-%m-%d'),
                'user_id': user_id,
                'res_model_id': model_id,
                'res_id': user_id,
            }]
        )

    def send_notification(self, user_id: int, title: str, message: str):
        # Get partner ID for user
        partner_id = self._models.execute_kw(
            self.db, self._uid, self.password,
            'res.users', 'read',
            [user_id],
            {'fields': ['partner_id']}
        )[0]['partner_id'][0]

        # Send bus notification
        self._models.execute_kw(
            self.db, self._uid, self.password,
            'bus.bus', '_sendone',
            [
                f'res.partner_{partner_id}',
                'simple_notification',
                {
                    'title': title,
                    'message': message,
                    'sticky': True,
                    'type': 'warning',
                }
            ]
        )
```

---

## Chatwoot Webhook Configuration

After deploying the notifier, register the webhook in Chatwoot:

```bash
# Via Rails console
kubectl exec -n business-system chatwoot-web-xxx -- bundle exec rails runner '
account = Account.find(1)
Webhook.create!(
  account_id: account.id,
  url: "http://chatwoot-notifier.business-system.svc.cluster.local:5000/webhook/chatwoot",
  subscriptions: ["conversation_created", "conversation_updated", "message_created"]
)
puts "Webhook created!"
'
```

Or via API:

```bash
curl -X POST "https://chat.haydenagencies.com.au/api/v1/accounts/1/webhooks" \
  -H "api_access_token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "http://chatwoot-notifier.business-system.svc.cluster.local:5000/webhook/chatwoot",
    "subscriptions": ["conversation_created", "conversation_updated", "message_created"]
  }'
```

---

## Secrets Required

### chatwoot-notifier secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: chatwoot-notifier
  namespace: business-system
type: Opaque
stringData:
  chatwoot-api-token: "..."      # From Chatwoot admin settings
  odoo-user: "admin"             # Or dedicated API user
  odoo-password: "..."           # Odoo user password
  smtp-username: "..."           # If different from Chatwoot SMTP
  smtp-password: "..."
```

---

## Implementation Phases

### Phase 1: Core Service
- [ ] Create Python Flask application
- [ ] Implement webhook receiver
- [ ] Implement Chatwoot API client
- [ ] Basic SLA breach detection

### Phase 2: Odoo Integration
- [ ] Implement Odoo XML-RPC client
- [ ] Activity creation
- [ ] User email mapping

### Phase 3: Kubernetes Deployment
- [ ] Create Dockerfile
- [ ] Build and push to GHCR
- [ ] Create Kubernetes manifests
- [ ] Deploy to cluster

### Phase 4: Chatwoot Configuration
- [ ] Register webhook
- [ ] Test end-to-end flow
- [ ] Monitor and tune

### Phase 5: Enhancements
- [ ] Add Slack integration (optional)
- [ ] Add bus notifications for instant popups
- [ ] Add metrics/monitoring
- [ ] Add SLA warning (pre-breach) notifications

---

## Testing

### Local Development

```bash
# Run locally with ngrok for webhook testing
ngrok http 5000

# Update Chatwoot webhook URL temporarily
# Test by creating a conversation in Chatwoot
```

### Cluster Testing

```bash
# Check logs
kubectl logs -n business-system -l app.kubernetes.io/name=chatwoot-notifier -f

# Test webhook manually
kubectl exec -n business-system chatwoot-web-xxx -- curl -X POST \
  http://chatwoot-notifier.business-system.svc.cluster.local:5000/webhook/chatwoot \
  -H "Content-Type: application/json" \
  -d '{"event": "conversation_updated", "id": 1, "account": {"id": 1}}'
```

---

## References

- [Chatwoot Webhook Events](https://www.chatwoot.com/docs/product/others/webhook-events)
- [Chatwoot API Docs](https://developers.chatwoot.com/api-reference/introduction)
- [Odoo External API](https://www.odoo.com/documentation/17.0/developer/reference/external_api.html)
- [Odoo mail.activity](https://www.odoo.com/forum/help-1/create-a-mailactivity-with-python-code-190117)
