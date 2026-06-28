# duitku — Malaysian bank statement parser

> Design doc. Status: **proposed**, not implemented.
> Owner: Ian. Last updated: 2026-06-28.

`duitku` is a parser + transaction normaliser for Malaysian retail bank
statements. It eats PDF and CSV statements from Maybank, UOB, and Ryt
Bank, emits a canonical transaction stream, and ships a small set of
emitters that push that stream into downstream personal-finance tools.

The first emitter target — and the immediate reason this exists — is
the homelab's self-hosted Firefly III at
`https://finance.62a.quanianitis.com`. But `duitku` is deliberately
factored so the parsers and the normaliser don't know that. Future
emitters can target Actual Budget, GnuCash, Lunch Money, or plain JSON
on stdout with no changes to the bank-specific code.

## 0. About the name

*duitku* = *duit* (Malay: money, cash) + *-ku* (1st-person possessive
suffix). Literally "my money". Short, unambiguous, distinctly
Malaysian, and reads naturally in both Malay and English contexts:
*"duitku ke mana?"* ("where did my money go?") is exactly the
question this tool answers.

## 1. Why this exists

Firefly III (and every other personal-finance tool) only knows about
transactions that someone tells it about. Manually re-keying a month
of statements is the path of least enjoyment. Existing open-source
importers target US and EU banks; the Malaysian retail-banking world
is documented mostly via blog posts, half-finished gists, and reverse-
engineered PDF layouts.

`duitku` is the bit Ian needs for himself, packaged so the rest of the
Malaysian self-hosting / personal-finance community doesn't have to
reinvent the same three parsers.

The three target banks were picked by what Ian actually uses:

- **Maybank** (Malayan Banking Berhad, MY) - primary daily-driver
- **UOB** (United Overseas Bank, MY/SG) - secondary
- **Ryt Bank** (YTL-SEA digital bank, MY) - new digital account

Other Malaysian banks (CIMB, Public Bank, HLB, RHB, AmBank, BSN…)
are out of scope for the first release but are explicit target
extensions; the parser interface is shaped so adding `parsers/cimb/`
is a self-contained PR.

## 2. The painful constraint: no consumer-grade bank APIs

Open Banking is effectively absent for retail customers in Malaysia
and Singapore. None of the three target banks publishes a stable,
public, self-service REST API that an individual can authenticate
against to pull their own transactions.

That leaves the following input shapes we can actually rely on:

| Bank    | PDF e-statement | CSV export | App/portal scrape |
|---------|-----------------|------------|--------------------|
| Maybank | yes, monthly, password-protected | yes, via Maybank2u (last 3-6 months, .csv) | possible, fragile |
| UOB     | yes, monthly, password-protected | yes, via UOB Personal Internet Banking (.csv/.xlsx) | possible, fragile |
| Ryt Bank| yes, in-app export to PDF only   | **no** (as of 2026-06) | mobile-only, no portal |

**Design choice:** target PDF + CSV ingestion. Screen scraping is out
of scope - it breaks every time the bank ships a redesign, almost
certainly violates ToS, and demands a headless browser pod we'd then
have to babysit for security updates.

This means `duitku` is a **batch, pull-from-files** tool, not a
real-time bank-feed integration. That's the most reversible shape and
matches what the banks will actually give us.

## 2.5 Project shape: library vs. homelab deployment

`duitku` is two artefacts:

1. **`duitku` (the library + CLI).** Open-source, framework-agnostic,
   intended to live in its own repo (`github.com/ian-cq/duitku`,
   eventually MIT/Apache-2.0). Knows about Malaysian banks; knows
   nothing about Firefly III, k8s, SMTP, or this homelab. Anyone
   running any personal-finance tool on any OS can pip-install it.

   ```
   duitku/
     parsers/
       maybank/
       uob/
       ryt/
     normaliser/        # RawTransaction -> canonical Transaction
     emitters/
       json/            # emit canonical JSON to stdout
       csv/             # emit canonical CSV
       firefly/         # POST to Firefly III /api/v1/transactions
       actual/          # (future) Actual Budget API
     cli.py             # `duitku parse stmt.pdf --bank maybank --emit firefly --to https://...`
   ```

2. **The homelab deployment (this doc, sections 3-10).** A specific
   way of running `duitku` inside Ian's k3s cluster, fed by inbound
   SMTP, posting to the local Firefly III instance. Lives under
   `infra/charts/duitku/` in the homelab repo. Not portable, not
   open-source, just one of N possible operating environments for
   the `duitku` library.

This split is load-bearing for three reasons:
- It keeps bank-parser fixes (the maintenance burden everyone shares)
  in a public repo where other Malaysians can contribute and benefit.
- It keeps homelab-specific opinions (SMTP, OIDC, FRP, longhorn) out
  of the public repo, so a windows-laptop user can `pip install duitku`
  and just run the CLI.
- It makes the homelab deployment's Argo Application a thin wrapper
  around a versioned `duitku` container image, not a code-and-config
  tangle.

The rest of this doc is the **homelab deployment**. The library
design (parser interfaces, normaliser schema, emitter contract) is
sketched here because the homelab needs all three to exist, but the
canonical home of that design will be `duitku`'s own README once the
repo is real.

---

## 3. High-level architecture

```
+--------------------+   email to                +---------------------+
|  user (Ian)        |   insert@mail             |  inbound SMTP       |
|  forwards bank     |   .quanianitis.com        |  receiver pod       |
|  statement email   | ------------------------> |  (aiosmtpd)         |
+--------------------+                           +----------+----------+
                                                            |
                                                            | write attachments
                                                            v
                                                  +---------------------+
                                                  |  landing PVC        |
                                                  |  /landing/{bank}/   |
                                                  +----------+----------+
                                                             |
                                                             v
                                                  +-----------------+
                                                  | parsers/        |
                                                  |  - maybank      |
                                                  |  - uob          |
                                                  |  - ryt          |
                                                  +--------+--------+
                                                           |
                                                           v
                                                  +---------------+
                                                  | normaliser    |
                                                  | -> canonical  |
                                                  |   Transaction |
                                                  +-------+-------+
                                                          |
                                                          v
                                                  +---------------+
                                                  | dedup store   |
                                                  | (sqlite PVC)  |
                                                  +-------+-------+
                                                          |
                                                          v
                                                  +---------------+
                                                  | firefly       |
                                                  | client        |
                                                  | POST /api/v1/ |
                                                  |   transactions|
                                                  +-------+-------+
                                                          |
                                                          v
                                                  finance.62a.quanianitis.com
```

The pipeline is a five-stage transform: **receive -> parse -> normalise
-> dedup -> post**. Each stage is independently replaceable and testable.

---

## 4. Component design

### 4.1 Ingestion: inbound SMTP at `insert@mail.quanianitis.com`

The **sole** input path is email. Ian forwards (or auto-forwards) the
bank's statement email to `insert@mail.quanianitis.com`, and the homelab
receives it via its own SMTP listener.

#### Why SMTP, not HTTP upload or IMAP polling

- **No outbound polling of a third party.** An IMAP poller against
  Gmail would mean storing a Gmail app password and depending on
  Google's IMAP staying available. Inbound SMTP makes the homelab
  authoritative: bank emails are forwarded straight at us.
- **No manual `kubectl cp` or web-form upload** that Ian has to
  remember to do. The statement workflow becomes "forward the email
  and forget"; everything after that is automatic.
- **One ingestion code path, not two.** Removes the HTTP upload
  endpoint and the IMAP poller that earlier drafts of this doc
  carried.

#### Protocol shape

- The receiver is **a single SMTP listener pod** running
  [`aiosmtpd`](https://aiosmtpd.aio-libs.org/), the asyncio SMTP
  server from the Python stdlib lineage. ~150 LOC of glue: validate
  envelope, parse MIME, write attachments to `/landing/{bank}/inbox/`.
- It accepts connections on **port 25 with STARTTLS** (cert from the
  same `wildcard-62a-quanianitis-com-tls` Secret if we publish the
  listener as `mail.62a.quanianitis.com`, or a separate cert if it
  lives under the bare `quanianitis.com`).
- Maximum message size: 25 MiB (bank PDFs are typically <2 MiB; 25 MiB
  is the safe upper bound that matches Gmail's outbound limit, so
  whatever Ian's mailer can send, we can receive).
- No outbound mail. The pod **does not relay**. It is an MX endpoint
  only.

#### How a message becomes a parsed transaction

1. Sender (Ian's mail account, or a Gmail forwarding rule) DELIVERs a
   message to `insert@mail.quanianitis.com`.
2. DNS MX record for `mail.quanianitis.com` (the delegated subdomain;
   see section 9 for the layout decision and the reasoning against
   touching the apex) routes the connection to the VPS public IP
   `103.40.207.125`; FRP TCP-forwards `:25` to the SMTP pod's
   pinned-ClusterIP Service.
3. The SMTP listener accepts, runs the sender-allowlist check (see
   below), persists the raw `.eml` to
   `/landing/_raw/{YYYY-MM-DD}-{message-id}.eml` for audit, then
   walks the MIME tree for attachments matching `*.pdf` / `*.csv`.
4. The `bank` (which subdirectory of `/landing/` to drop the file in)
   is selected from, in order:
     a. an `X-Firefly-Bank: maybank|uob|ryt` header if the forwarding
        mailer adds one,
     b. the Subject line (regex match on bank names),
     c. the From address (the bank's known sender domain),
     d. fallback: `/landing/_unsorted/inbox/` for the parser sweep to
        retry classification.
5. The parser sweep CronJob picks the file up on its next tick (see
   section 5).

#### Abuse model and sender allowlist

`insert@mail.quanianitis.com` is a guessable local-part on a domain
that publishes WHOIS data via its registrar. We must assume strangers
will eventually try to send to it. Three reinforcing controls:

1. **Sender allowlist.** A Secret-mounted list of permitted envelope
   `MAIL FROM` addresses (Ian's primary mail, plus the banks' known
   no-reply senders). Anything else gets a 5xx reject in the SMTP
   `RCPT TO` stage so we don't even store the message.
2. **SPF + DMARC enforcement.** The listener uses
   [`authres`](https://launchpad.net/authentication-results-python) /
   `dkimpy` to verify the message's SPF + DKIM + DMARC alignment
   before accepting. Failures get a 5xx.
3. **Attachment-only acceptance.** If the message has no PDF/CSV
   attachment, it's discarded (logged, not bounced - bouncing would
   leak that the address is live).

The raw `.eml` retention under `/landing/_raw/` is 90 days, rotated by
a separate CronJob.

#### Landing PVC layout

```
/landing/
  _raw/                            <- raw .eml messages, 90-day retention
  _unsorted/
    inbox/                         <- attachments we couldn't classify
    failed/
  maybank/
    inbox/                         <- newly extracted attachments
    processed/                     <- moved here after successful import
    failed/                        <- moved here on parse error + .err sidecar
  uob/
    inbox/
    processed/
    failed/
  ryt/
    inbox/
    processed/
    failed/
  state.db                         <- sqlite dedup store (see 4.4)
```

The SMTP listener only writes to `_raw/` and the per-bank `inbox/`s.
The parser sweep CronJob owns everything else.

### 4.2 Parsers

One module per bank under `parsers/`. Each parser exposes a single
function:

```python
def parse(path: Path, password: str | None) -> Iterable[RawTransaction]: ...
```

The `RawTransaction` it yields is bank-specific (whatever fields the
statement actually contains). Normalisation is a separate step.

**Maybank.** Two input shapes:
- `*.pdf` (monthly e-statement, password = last 6 digits of IC).
  Library: `pdfplumber` for table extraction. The statement has a
  predictable header row (`Date | Description | Cheque No. | Debit |
  Credit | Balance`) and each transaction is one row with optionally
  multi-line description in the `Description` cell.
- `*.csv` (Maybank2u transaction history download).
  Library: stdlib `csv`. Columns are documented and stable.

**UOB.** Two input shapes:
- `*.pdf` (monthly e-statement, password = DOB in `DDMMYY` or NRIC
  last 6, varies by product).
  Library: `pdfplumber`. The PDF is more graphical than Maybank's;
  expect to fall back to positional text extraction
  (`page.extract_words()` with x/y filtering) if table extraction
  misses rows.
- `*.csv` (UOB Personal Internet Banking export).
  Library: stdlib `csv`. Be aware the CSV is sometimes UTF-16 LE with
  BOM; detect via `charset-normalizer`.

**Ryt Bank.** One input shape:
- `*.pdf` (in-app export, **no CSV available**).
  Ryt is brand-new (launched late 2025) so the statement format is
  still settling. Expected shape per their app: a header block with
  account number + period, then a flat transaction list with `Date,
  Time, Description, Amount, Running Balance`. Library: `pdfplumber`;
  may need to extract via `page.extract_text()` and regex rather than
  tables, depending on layout.

Each parser writes to `/landing/{bank}/failed/<file>.err` on exception
and re-raises so the orchestrator can move the file aside.

### 4.3 Normaliser

Bank-specific `RawTransaction` -> canonical `Transaction`. The
canonical model:

```python
class Transaction(BaseModel):
    bank: Literal["maybank", "uob", "ryt"]
    account_id: str            # last 4 of account number, or full masked PAN
    date: date                 # transaction date, NOT posting date when both exist
    amount: Decimal            # always positive; direction encoded in `kind`
    currency: str              # ISO 4217 - MYR / SGD / USD / ...
    kind: Literal["withdrawal", "deposit"]
    description: str           # cleaned, multi-line collapsed to single line
    raw_description: str       # original, for audit / re-categorisation
    external_id: str           # see 4.4
```

Sign conventions in source statements are inconsistent (Maybank: two
columns Debit/Credit; UOB: one column with sign; Ryt: one column with
sign). The normaliser unifies on positive `amount` + `kind`.

### 4.4 Deduplication

Two reinforcing mechanisms:

1. **Local sqlite under `/landing/state.db`.** Table `seen_transactions`
   with primary key `external_id`. Insert before POSTing to Firefly;
   on conflict, skip. This survives Firefly being briefly unreachable
   without re-POSTing on retry.
2. **Firefly `external_id` field.** Firefly itself rejects duplicates
   when `external_id` collides within the same asset account, which
   means even if the sqlite is lost the data store stays clean.

`external_id` is computed as:

```
sha256("{bank}|{account_id}|{date:YYYY-MM-DD}|{amount:0.2f}|{kind}|{raw_description}")[:32]
```

The hash is over `raw_description` (not the cleaned one) so reformatting
the cleaner doesn't invalidate the dedup key for historical imports.

### 4.5 Emitter: Firefly III client

The first concrete emitter implementation. Other emitters (Actual,
GnuCash, plain JSON) follow the same shape: receive canonical
`Transaction` objects, push them somewhere, idempotently.

Thin wrapper around `POST /api/v1/transactions`. Auth via a Firefly
**Personal Access Token** (issued from the Firefly UI under Profile ->
OAuth -> Personal Access Tokens), stored as a k8s Secret
`duitku-firefly-token`.

The token is a JWT; Firefly does not currently expose a rotation API,
so rotation = create a new PAT, update the Secret, roll the pod, then
revoke the old PAT from the UI.

Request body shape (one transaction):

```json
{
  "error_if_duplicate_hash": true,
  "apply_rules": true,
  "transactions": [{
    "type": "withdrawal",
    "date": "2026-06-15",
    "amount": "42.50",
    "currency_code": "MYR",
    "description": "GRAB*RIDE KL",
    "source_name": "Maybank Savings ****1234",
    "destination_name": "(unknown)",
    "external_id": "ab12...32hex",
    "notes": "raw: GRAB*RIDE KL  REF 0192834712"
  }]
}
```

`source_name` / `destination_name` lookup table is wired by Ian once
in `config/accounts.yaml`:

```yaml
maybank:
  "1234": "Maybank Savings ****1234"   # MY savings
uob:
  "5678": "UOB One ****5678"
ryt:
  "9012": "Ryt Bank ****9012"
```

If `account_id` from the parsed statement isn't in the table, the
importer **fails the file** rather than guessing - silently picking the
wrong source account is worse than not importing.

`apply_rules: true` lets Firefly's own rules engine categorise the
transaction (assign category, budget, tags). That keeps
categorisation logic *in Firefly* where Ian can edit it from the UI,
instead of forking categorisation into a second place inside the
importer.

---

## 5. Deployment shape

Lives under `infra/charts/duitku/` alongside `firefly/`.

Resources:

- **Namespace** `duitku` (separate from `firefly` so an
  importer crash never threatens the data store; CrashLoopBackOff
  noise is localised).
- **PVC** `landing` (longhorn, 5 Gi) mounted at `/landing`.
- **Deployment** `duitku-smtp` running the `aiosmtpd`
  listener. 1 replica, `Recreate` strategy. Mounts the `landing` PVC
  and the wildcard TLS Secret. Exposes container port 25.
  Liveness: TCP probe on 25. Readiness: same.
- **Service** `duitku-smtp` of type `LoadBalancer` (or
  `ClusterIP` fronted by a Gateway-API `TCPRoute` if cilium / Envoy
  Gateway is configured for TCP - see open questions). Port 25 only.
- **CronJob** `duitku-sweep` runs every 15 minutes,
  `command: ["python", "-m", "importer.sweep"]`. It scans
  `/landing/_unsorted/inbox/` (to classify late) and
  `/landing/{bank}/inbox/` (to parse + post), and moves files to
  `processed/` or `failed/`. Mounts the same `landing` PVC. The SMTP
  pod and the sweep pod share the PVC RWO but never touch the same
  files: SMTP only writes new files into `_raw/` + `{bank}/inbox/`,
  sweep only reads from `inbox/` and writes to `processed/` / `failed/`
  / `state.db`. RWO holds because the Deployment uses Recreate and
  the CronJob has `concurrencyPolicy: Forbid`; node-affinity is not
  required because longhorn handles cross-node RWO via its CSI.
- **CronJob** `duitku-prune-raw` runs daily, deletes `*.eml`
  in `_raw/` older than 90 days.
- **Secret** `duitku` holding `FIREFLY_PAT` (the Firefly III PAT for
  the firefly emitter), `MAYBANK_PDF_PASSWORD`, `UOB_PDF_PASSWORD`,
  `RYT_PDF_PASSWORD`, and `SENDER_ALLOWLIST` (newline-separated
  envelope-from addresses).
  Inline initially, eventually ExternalSecret pointing at 1Password
  (same followup as the Firefly and Plane stacks).
- **ConfigMap** `duitku-accounts` holding `accounts.yaml`
  (the bank-account-id -> Firefly-asset-account-name lookup).
  Mounted at `/etc/duitku/accounts.yaml`. Updating this is
  the routine maintenance Ian will actually do.

There is **no HTTPRoute and no ingress for `duitku`**. The service
is reachable from the internet only via SMTP on port 25. Health and
metrics are scraped in-cluster, never exposed externally.

Argo Application registered the same way as `firefly`:
`deployments/applications/services/duitku.yaml` ->
`infra/charts/duitku/`, included in the services
kustomization.

---

## 6. Firefly III prep (one-time, for the firefly emitter)

These steps are specific to the Firefly emitter. A future Actual /
GnuCash emitter would have its own analogous one-time setup. Before
the firefly emitter runs, Ian needs to:

1. Log into Firefly at https://finance.62a.quanianitis.com (Google
   OIDC will provision the first user).
2. Create asset accounts for each real bank account, matching the
   names in `accounts.yaml` exactly. e.g. "Maybank Savings ****1234".
3. Set each account's currency (MYR for Maybank / Ryt, MYR or SGD for
   UOB depending on product).
4. Profile -> OAuth -> "Create new token", scope `Personal Access
   Token`, copy the JWT into the `FIREFLY_PAT` Secret.
5. Optionally pre-create a few rules (e.g. "if description matches
   `GRAB*` then category = Transport") so `apply_rules: true` does
   useful work from day one.

These steps are **not** in `duitku`'s responsibility - importing
into Firefly accounts that don't exist would silently create them with
wrong currencies / types.

---

## 7. Phasing

Smallest reversible step first. Each phase ends with something Ian
can actually use.

| Phase | Scope | Deliverable |
|-------|-------|-------------|
| 0 | This doc, agreed | `docs/duitku.md` (this file) |
| 1 | Maybank PDF only, CLI tool, no k8s, no SMTP | Local Python script Ian runs by hand on a downloaded statement; first month of Maybank data lands in Firefly |
| 2 | Add Maybank CSV + UOB PDF + UOB CSV parsers | Same CLI, more parsers; parsers are now proven against real data |
| 3 | Stand up the SMTP receiver: DNS for `mail.quanianitis.com`, open port 25 on the VPS firewall, FRP `:25` proxy to a pinned-ClusterIP SMTP Service, `aiosmtpd` Deployment, sender allowlist + SPF/DMARC enforcement | Forwarding a bank statement email to `insert@mail.quanianitis.com` lands the attachment in `/landing/{bank}/inbox/` |
| 4 | Wire the CronJob sweep to the SMTP-fed inboxes; full pipeline ingest -> Firefly | Hands-off monthly imports for Maybank + UOB |
| 5 | Add Ryt parser once a real Ryt PDF is available | Three banks supported |
| 6 | Move Secrets to 1Password + external-secrets | Token rotation is no longer a `kubectl edit` operation |

Phases 1 and 2 happen entirely outside k8s; this keeps the "is the
parser correct" question separate from the "is the SMTP and deploy
correct" question. We only graduate to k8s once the parsers are
stable on a month of real data.

---

## 8. Decisions taken (and the alternatives ruled out)

- **Pull from files, not from bank APIs.** Already covered in section 2.
- **PDF + CSV, not browser scraping.** Headless-browser scraping (e.g.
  Playwright against Maybank2u) was considered and rejected: high
  maintenance, fragile to UI changes, almost certainly against the
  bank's ToS, and needs a fat container with Chromium + a way to
  handle 2FA prompts.
- **Inbound SMTP, not HTTP upload or IMAP polling.** SMTP makes the
  homelab the authoritative inbox: no outbound creds to store, no
  manual upload step. The cost is running a public-internet-facing
  port-25 listener, which is mitigated by sender allowlist +
  SPF/DMARC enforcement + attachment-only acceptance (section 4.1).
- **One language (Python), one parser style (`pdfplumber` + regex
  fallback).** Considered splitting per-bank tooling (e.g. Tabula for
  Java-backed PDF table extraction). Not worth the deploy complexity
  for three banks.
- **External `apply_rules: true`, not in-importer categorisation.**
  Categorisation lives in Firefly's rules engine so Ian edits it in
  one place via the Firefly UI.
- **Sqlite + Firefly `external_id`, not just one.** Belt and braces,
  because losing the sqlite to a PVC mishap should not double-post
  six months of transactions to Firefly.
- **Separate namespace from `firefly`.** A buggy parser must not be
  able to crash the data store via shared-namespace pressure or RBAC
  blast radius.
- **`aiosmtpd`, not a full MTA like Postfix.** The receiver only needs
  to accept-or-reject, parse MIME, and write files. Postfix would
  bring a queue, a delivery agent, alias maps, root-privileged
  components, and an ongoing CVE-watching duty for ~5% of features we
  use. `aiosmtpd` is one Python module we already understand.
- **Phase 1 is a CLI, not a service.** Deploying before the parsers
  are real wastes a sync loop on yaml that doesn't do anything yet.

---

## 9. Open questions / decisions deferred

- **DNS layout: subdomain delegation, `insert@mail.quanianitis.com`.**
  Investigated on 2026-06-28. Apex `quanianitis.com` already publishes
  MX records pointing at Cloudflare Email Routing
  (`route1/2/3.mx.cloudflare.net`); the TXT/SPF mixes Cloudflare and
  Google. Flipping the apex MX would silently break unrelated
  personal mail.

  Decision: **delegate `mail.quanianitis.com`** to the homelab.
  - `A    mail.quanianitis.com   103.40.207.125`   (DNS-only on
    Cloudflare; Cloudflare does not proxy SMTP)
  - `MX   mail.quanianitis.com   10 mail.quanianitis.com.`
  - `TXT  mail.quanianitis.com   "v=spf1 ip4:103.40.207.125 -all"`
    (we receive only; -all defends against forged outbound)
  - `TXT  _dmarc.mail.quanianitis.com
        "v=DMARC1; p=reject; rua=mailto:insert@mail.quanianitis.com"`

  The canonical address Ian forwards to becomes
  `insert@mail.quanianitis.com`. Apex mail is untouched.

- **Port 25 inbound on the VPS.** Probed on 2026-06-28 from inside
  the homelab: `nc -zv 103.40.207.125 25` returned **connection
  timed out** (silently dropped, not RST). Cause is either VPS-side
  iptables/ufw or IPServerOne's (AS45352) network edge. Distinguishing
  requires an interactive SSH session to the VPS, which the
  unattended agent context does not have.

  Plan:
    a. Open inbound 25 on the VPS firewall first (`iptables -A INPUT
       -p tcp --dport 25 -j ACCEPT`, persist via the same mechanism
       the existing `:443` rule uses). Cheap and reversible.
    b. Re-probe externally. If still timing out, file a ticket with
       IPServerOne to lift any network-edge filter on inbound 25.
    c. Mirror the existing `:443 -> 10.43.201.212` FRP proxy entry:
       add a new `frpc.toml` TCP proxy `:25 -> <smtp service
       ClusterIP>:25`. The SMTP Service must use a **pinned
       ClusterIP** like `cilium-gateway-public` does (see
       `frps/frp-client/README.md` for the operator-scale-down dance
       used to pin ClusterIPs).

  Until (a) and (b) are confirmed, phase 3 cannot ship.

- **STARTTLS cert.** With the subdomain decision above, cert-manager
  mints a dedicated cert for `mail.quanianitis.com` via the same
  Let's Encrypt issuer the rest of the cluster uses. (Reusing the
  `*.62a.quanianitis.com` wildcard would force the public hostname to
  contain `62a`, which leaks "this is the homelab" in MX records -
  not a security issue but mildly ugly.)
- **Backscatter and bounces.** The receiver must **never** generate a
  bounce after accepting a message. Rejections happen at the SMTP
  layer (5xx during `RCPT TO` or `DATA`); accepted-then-discarded
  silently drops, no NDR. This is enforced in code by simply not
  having any outbound-mail capability in the pod.
- **PDF passwords.** Maybank/UOB e-statements are password-locked. The
  password per product is documented in the bank's covering email but
  is *not* the same for every account. Plan: one Secret key per bank
  (`MAYBANK_PDF_PASSWORD` etc.) and assume same password across all
  PDFs from that bank. If Ian has multiple Maybank products with
  different passwords, this becomes a map - revisit in phase 1.
- **Multi-currency on UOB.** If Ian holds a UOB SGD account *and* a
  UOB MYR account, the `account_id`-to-currency mapping must come
  from `accounts.yaml`, not be inferred from the statement. Already
  encoded in section 4.5's lookup table.
- **Foreign currency transactions on any card.** A MYR account can
  still have an FX transaction (e.g. USD charge); Firefly stores both
  the source amount + the foreign amount. Phase 1 will just import the
  account-currency amount and put the FX detail in `notes`; phase 2
  can populate `foreign_amount` + `foreign_currency_code` properly.
- **Statement-vs-posting-date.** Some statements show both. We pick
  transaction date (the date the customer made the spend), not
  posting date, because that's what humans remember and what Firefly's
  rules engine matches against.
- **Reconciliation against statement balance.** The importer could
  cross-check that sum-of-debits + sum-of-credits + opening balance =
  closing balance per the statement, and refuse to publish if off.
  Nice to have, phase 4.5.

---

## 10. Followups for future agents / Ian

- File path **does not exist yet on disk** - this doc is the plan,
  nothing under `infra/charts/duitku/` is implemented.
- When phase 1 starts: scaffold the CLI in a separate repo (or
  `tools/duitku/` in the homelab repo) before any k8s
  manifests. The k8s side is the easy part.
- The SMTP receiver is the only piece that *takes input from outside
  the homelab*. The raw `.eml` retention under `/landing/_raw/`
  contains bank statement attachments and full message headers; treat
  it like the note gardens: no exfiltration, no embedding into
  external services, no backups outside the homelab without explicit
  consent.
- Before phase 3 ships: verify port 25 inbound actually reaches the
  homelab from the public internet, and decide the MX layout
  (apex vs. subdomain delegation). See section 9.
- If `quanianitis.com` already has MX records pointing at Google
  Workspace or similar, **do not** flip the apex MX without Ian
  explicitly agreeing - that would silently break unrelated email
  flows. Subdomain delegation is the safe path.
