"""Private, versioned native messaging state machine; no terminal transport."""

import datetime
import base64
import hashlib
import json
import os
import secrets
import subprocess
import uuid


PROTOCOL = "cmux-maestro.native-messaging"
VERSION = 1
MAX_MESSAGES = 64
MAX_BODY = 4096
MAX_TTL = 3600
RETENTION = 86400
STATES = {"queued", "inflight", "unknown", "delivered", "acknowledged",
          "replied", "expired", "rejected"}


class NativeMessaging:
    def __init__(self, api):
        self.api = api
        self.error = api["OrchestrationError"]

    def fail(self, text):
        raise self.error(text)

    def date(self, value, field):
        parsed = self.api["parse_date"](value, field)
        if parsed.tzinfo is None:
            self.fail(f"{field} must include a timezone.")
        return parsed

    def identity(self, node):
        return {"nodeId": node["id"], "sessionId": node.get("copilotSessionId"),
                "generation": node["generation"], "runId": node["runId"]}

    def launch_request(self, args, root, actor, settings, policy, cwd):
        if os.environ.get("COPILOT_HOME") is not None or os.environ.get("XDG_CONFIG_HOME") is not None:
            self.fail("Native messaging supports only the standard Copilot configuration home.")
        if not settings.get("copilotAccount") or not settings.get("model"):
            self.fail("Native launches require pinned account and model.")
        timestamp = self.api["now_date"]()
        request = {
            "version": VERSION, "requestId": str(uuid.uuid4()),
            "actor": self.identity(actor), "parentToolPolicy": actor["toolPolicy"],
            "workerId": str(uuid.uuid4()), "sessionId": str(uuid.uuid4()),
            "workerGeneration": 1,
            "launchSettings": settings, "toolPolicy": policy,
            "mode": "interactive-exact-tools",
            "parentPolicy": "unknown-human-fallback",
            "cwd": str(cwd), "name": args.name, "task": args.task,
            "createdAt": timestamp.isoformat(),
            "expiresAt": (timestamp + datetime.timedelta(minutes=10)).isoformat(),
        }
        encoded = json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
        if len(encoded) > 49152:
            self.fail("Native authorization request is too large.")

        def write(store):
            state = store.read()
            current = self.api["authorize"](state, args.actor_id, args.token)
            if self.identity(current) != request["actor"] or current["toolPolicy"] != request["parentToolPolicy"]:
                self.fail("Actor changed before policy authorization.")
            # Requests are dismissed explicitly in the UI, never evicted while awaiting review.
            names = [name for name in os.listdir(store.control_fd)
                     if name.startswith("native-request-") and name.endswith(".json")]
            if len(names) >= 16:
                self.fail("Pending native authorization limit reached; remove reviewed requests through Maestro.")
            store._atomic(store.control_fd, f"native-request-{request['requestId']}.json", encoded)
        self.api["with_store"](root, write)
        return {"status": "human-authorization-required", "requestId": request["requestId"],
                "instruction": "Review this exact request in Maestro Agent launch settings."}

    def authorized_launch(self, args, root, actor, settings, policy, cwd):
        if os.environ.get("COPILOT_HOME") is not None or os.environ.get("XDG_CONFIG_HOME") is not None:
            self.fail("Native messaging supports only the standard Copilot configuration home.")
        identifier = self.api["canonical_uuid"](args.native_request, "native request ID")

        def read(store):
            request = store._read_regular(f"native-request-{identifier}.json", 49152, private=True)
            receipt = store._read_regular(f"native-approval-{identifier}.json", 70000, private=True)
            config = store._read_regular("native-setup.json", 4096, private=True, directory=store.root_fd)
            if request is None or receipt is None or config is None:
                self.fail("Native launch requires explicit extension setup and genuine human authorization.")
            return request, receipt, config
        raw, receipt, config = self.api["with_store"](root, read, read_only=True)
        try:
            request, signed, setup = json.loads(raw), json.loads(receipt), json.loads(config)
            if set(signed) != {"request", "signature"} or base64.b64decode(signed["request"], validate=True) != raw:
                self.fail("Human authorization does not cover this exact request.")
            if set(setup) != {"verifier", "version"} or setup["version"] != VERSION:
                self.fail("Native setup version is unsupported.")
            verifier = self.api["trusted_executable"](None, setup["verifier"])
            checked = subprocess.run([verifier, "--maestro-verify-native-authorization"],
                                     input=receipt, capture_output=True, timeout=10)
            if checked.returncode != 0 or checked.stdout.strip() != b'{"valid":true}':
                self.fail("Human authorization signature could not be verified.")
        except (ValueError, TypeError, KeyError, OSError, subprocess.TimeoutExpired) as error:
            raise self.error("Native authorization is invalid or its trusted app is unavailable.") from error
        expected = {
            "actor": self.identity(actor), "parentToolPolicy": actor["toolPolicy"],
            "launchSettings": settings, "toolPolicy": policy, "cwd": str(cwd),
            "name": args.name, "task": args.task, "mode": "interactive-exact-tools",
            "parentPolicy": "unknown-human-fallback", "version": VERSION, "requestId": identifier,
            "workerGeneration": 1,
        }
        if set(request) != set(expected) | {"workerId", "sessionId", "createdAt", "expiresAt"}:
            self.fail("Native authorization contains unsupported policy fields.")
        if any(request.get(key) != value for key, value in expected.items()):
            self.fail("Native authorization target or policy changed; request fresh human authorization.")
        created = self.date(request["createdAt"], "authorization creation")
        expiry = self.date(request["expiresAt"], "authorization expiry")
        if not created <= self.api["now_date"]() < expiry or (expiry - created).total_seconds() != 600:
            self.fail("Human authorization has expired or is not yet valid.")
        for field in ("workerId", "sessionId"):
            self.api["canonical_uuid"](request[field], field)
        return request

    def consume_authorization(self, state, request, actor):
        if self.identity(actor) != request["actor"] or actor["toolPolicy"] != request["parentToolPolicy"]:
            self.fail("Parent changed before launch; human authorization is stale.")
        used = state.setdefault("nativeAuthorizations", [])
        if request["requestId"] in [entry["id"] for entry in used]:
            self.fail("Human authorization has already been consumed.")
        current = self.api["now_date"]()
        if current >= self.date(request["expiresAt"], "authorization expiry"):
            self.fail("Human authorization expired before launch.")
        used[:] = [entry for entry in used
                   if self.date(entry["expiresAt"], "authorization expiry") > current]
        if len(used) >= 128:
            self.fail("Native authorization retention bound reached.")
        used.append({"id": request["requestId"], "expiresAt": request["expiresAt"]})

    def validate(self, state):
        used = state.get("nativeAuthorizations", [])
        if not isinstance(used, list) or len(used) > 128:
            self.fail("Native authorization retention is invalid.")
        used_ids = set()
        for entry in used:
            if not isinstance(entry, dict) or set(entry) != {"id", "expiresAt"}:
                self.fail("Stored authorization is malformed.")
            self.api["canonical_uuid"](entry["id"], "authorization ID")
            if entry["id"] in used_ids:
                self.fail("Stored authorization IDs are duplicated.")
            used_ids.add(entry["id"])
            self.date(entry["expiresAt"], "authorization expiry")
        messages = state.get("nativeMessages", [])
        if not isinstance(messages, list) or len(messages) > MAX_MESSAGES:
            self.fail("Native message retention limit exceeded.")
        seen = set()
        seen_ids = set()
        for item in messages:
            if not isinstance(item, dict) or set(item) != {
                "id", "key", "sender", "receiver", "body", "createdAt", "expiresAt",
                "state", "registration", "providerMessageId", "reply", "bodyHash", "replyHash",
            }:
                self.fail("Native message record is malformed.")
            self.api["canonical_uuid"](item["id"], "message ID")
            if item["id"] in seen_ids:
                self.fail("Native message IDs are duplicated.")
            seen_ids.add(item["id"])
            for identity in (item["sender"], item["receiver"]):
                if not isinstance(identity, dict) or set(identity) != {
                    "nodeId", "sessionId", "generation", "runId",
                }:
                    self.fail("Native message identity is malformed.")
                for field in ("nodeId", "runId"):
                    self.api["canonical_uuid"](identity[field], field)
                if identity["sessionId"] is not None:
                    self.api["canonical_uuid"](identity["sessionId"], "session ID")
                if type(identity["generation"]) is not int or identity["generation"] < 0:
                    self.fail("Native message generation is invalid.")
            if item["receiver"]["sessionId"] is None:
                self.fail("Native message receiver requires an exact session.")
            if item["receiver"]["runId"] != item["sender"]["runId"]:
                self.fail("Native message identities cross runs.")
            key = self.text(item["key"], 128)
            pair = (item["sender"]["nodeId"], key)
            if pair in seen or not isinstance(item["state"], str) or item["state"] not in STATES:
                self.fail("Native message key or state is invalid.")
            seen.add(pair)
            for field in ("body", "reply"):
                digest = item[f"{field}Hash"]
                if field == "reply" and item[field] is None and digest is None:
                    continue
                if (not isinstance(digest, str) or len(digest) != 64
                        or any(char not in "0123456789abcdef" for char in digest)):
                    self.fail("Native message content digest is invalid.")
                if item[field] is not None:
                    self.text(item[field], MAX_BODY)
                    if hashlib.sha256(item[field].encode()).hexdigest() != digest:
                        self.fail("Native message content digest does not match.")
            for field in ("registration", "providerMessageId"):
                if item[field] is not None:
                    self.text(item[field], 128)
            created = self.date(item["createdAt"], "message creation")
            expiry = self.date(item["expiresAt"], "message expiry")
            if (not 0 < (expiry - created).total_seconds() <= MAX_TTL
                    or created > self.api["now_date"]() + datetime.timedelta(minutes=5)):
                self.fail("Native message expiry is invalid.")
            if item["body"] is None and (self.api["now_date"]() - created).total_seconds() <= RETENTION:
                self.fail("Native message content was removed before retention elapsed.")
        for node in state["nodes"].values():
            native = node.get("nativeMessaging")
            if native is None:
                continue
            if (
                node["role"] != "worker" or node.get("executionMode") != "interactive"
                or not isinstance(native, dict)
                or set(native) != {"version", "credentialHash", "registration", "heartbeat", "ready", "closed"}
                or type(native["ready"]) is not bool or type(native["closed"]) is not bool
                or (native["ready"] and native["closed"])
                or type(native["version"]) is not int or native["version"] != VERSION
                or not isinstance(native["credentialHash"], str)
                or len(native["credentialHash"]) != 64
                or any(char not in "0123456789abcdef" for char in native["credentialHash"])
            ):
                self.fail("Native messaging registration is malformed.")
            if native["registration"] is not None:
                self.api["canonical_uuid"](native["registration"], "registration")
                heartbeat = self.date(native["heartbeat"], "registration heartbeat")
                if heartbeat > self.api["now_date"]() + datetime.timedelta(minutes=5):
                    self.fail("Native heartbeat is in the future.")
            elif native["heartbeat"] is not None or native["ready"]:
                self.fail("Native messaging heartbeat has no registration.")

    def text(self, value, maximum):
        value = self.api["bounded_text"](value, "native message field", maximum)
        if len(value.encode("utf-8")) > maximum:
            self.fail("Native message field exceeds its byte limit.")
        return value

    def maintain(self, state):
        current = self.api["now_date"]()
        messages = state.setdefault("nativeMessages", [])
        for item in messages:
            receiver = state["nodes"].get(item["receiver"]["nodeId"])
            sender = state["nodes"].get(item["sender"]["nodeId"])
            if item["state"] == "queued" and (
                receiver is None or sender is None
                or self.identity(receiver) != item["receiver"]
                or self.identity(sender) != item["sender"]
                or receiver.get("archiving") or sender.get("archiving")
            ):
                item["state"] = "rejected"
            if current >= self.date(item["expiresAt"], "expiry"):
                if item["state"] == "queued":
                    item["state"] = "expired"
                elif item["state"] == "inflight":
                    item["state"] = "unknown"
            if (current - self.date(item["createdAt"], "creation")).total_seconds() > RETENTION:
                # Keep bounded idempotency/order tombstones until explicit run archive.
                # Forgotten uncertain sends must never become eligible for automatic replay.
                item["body"], item["reply"] = None, None

    def capability(self, node):
        native = node.get("nativeMessaging")
        live = native and native["ready"] and native["registration"] is not None and (
            self.api["now_date"]() - self.date(native["heartbeat"], "heartbeat")
        ).total_seconds() < 30
        live = live and node["phase"] == "turn-running" and self.api["process_matches"](node)
        return {
            "protocol": PROTOCOL, "version": VERSION, "identity": self.identity(node),
            "status": "supported" if live else "unsupported",
            "reason": None if live else "No current opted-in, supervised adapter.",
            "maxBodyBytes": MAX_BODY, "maxTTLSeconds": MAX_TTL,
            "retentionSeconds": RETENTION, "peerMessaging": "unsupported",
            "maxUnarchivedMessages": MAX_MESSAGES, "idempotencyRetention": "until-run-archive",
            "transcripts": "unsupported", "taskCompletionInference": False,
            "policyMode": "interactive-exact-tools", "fullParentPolicyExport": "unsupported",
            "allowAll": "unsupported", "pathOrURLPolicyEmulation": "unsupported",
        }

    def command(self, root, request):
        if not isinstance(request, dict) or type(request.get("version")) is not int or request.get("version") != VERSION:
            self.fail("Unsupported native messaging protocol version.")
        operation = request.get("operation")
        if not isinstance(operation, str) or operation not in {"capabilities", "send", "read"}:
            self.fail("Unsupported native messaging operation.")
        allowed = {"version", "operation", "actorId", "token", "receiver"}
        if operation == "send":
            allowed |= {"key", "body", "ttlSeconds"}
        if set(request) - allowed:
            self.fail("Unknown native messaging request fields.")

        def apply(state):
            credential = request.get("token")
            if (not isinstance(credential, str) or len(credential) != 64
                    or any(char not in "0123456789abcdef" for char in credential)):
                self.fail("Actor control credential is invalid.")
            actor = self.api["authorize"](state, request.get("actorId"), credential)
            if actor["role"] == "worker" and not self.api["process_matches"](actor):
                self.fail("Sender supervisor identity is stale.")
            receiver = request.get("receiver")
            if not isinstance(receiver, dict):
                self.fail("An exact receiver identity is required.")
            target = self.api["ensure_owned"](state, actor, receiver.get("nodeId"), direct=True)
            if receiver != self.identity(target):
                self.fail("Receiver session, worker, run or generation is stale.")
            self.maintain(state)
            capability = self.capability(target)
            if operation == "capabilities":
                return capability
            pair = [item for item in state["nativeMessages"]
                    if item["sender"] == self.identity(actor) and item["receiver"] == receiver]
            if operation == "read":
                return {"protocol": PROTOCOL, "version": VERSION, "messages": pair}
            key = self.text(request.get("key"), 128)
            body = self.text(request.get("body"), MAX_BODY)
            ttl = request.get("ttlSeconds")
            if type(ttl) is not int or not 1 <= ttl <= MAX_TTL:
                self.fail("Native message TTL must be between 1 and 3600 seconds.")
            prior = next((item for item in state["nativeMessages"]
                          if item["sender"]["nodeId"] == actor["id"] and item["key"] == key), None)
            if prior:
                if (prior["bodyHash"] != hashlib.sha256(body.encode()).hexdigest()
                        or prior["receiver"] != receiver or prior["sender"] != self.identity(actor)):
                    self.fail("Idempotency key was reused with different content or identity.")
                if (self.date(prior["expiresAt"], "expiry")
                    - self.date(prior["createdAt"], "creation")).total_seconds() != ttl:
                    self.fail("Idempotency key was reused with a different TTL.")
                return {"protocol": PROTOCOL, "version": VERSION, "message": prior}
            if capability["status"] != "supported":
                return capability
            if len(state["nativeMessages"]) >= MAX_MESSAGES:
                self.fail("Native queue is full; retained idempotency keys cannot be evicted early.")
            timestamp = self.api["now_date"]()
            item = {
                "id": str(uuid.uuid4()), "key": key,
                "sender": self.identity(actor), "receiver": receiver, "body": body,
                "bodyHash": hashlib.sha256(body.encode()).hexdigest(), "replyHash": None,
                "createdAt": timestamp.isoformat(),
                "expiresAt": (timestamp + datetime.timedelta(seconds=ttl)).isoformat(),
                "state": "queued", "registration": None, "providerMessageId": None, "reply": None,
            }
            state["nativeMessages"].append(item)
            return {"protocol": PROTOCOL, "version": VERSION, "message": item}
        return self.api["mutate"](root, apply)

    def bridge(self, root, request):
        """Only a generation-scoped bridge credential can receive or reply."""
        if not isinstance(request, dict) or type(request.get("version")) is not int or request.get("version") != VERSION:
            self.fail("Unsupported native bridge protocol version.")
        if set(request) - {"version", "operation", "identity", "credential", "registration",
                           "messageId", "providerMessageId", "body"}:
            self.fail("Unknown bridge fields.")
        operation = request.get("operation")
        if not isinstance(operation, str) or operation not in {
            "register", "ready", "poll", "delivered", "unknown", "expired", "acknowledge", "reply", "close",
        }:
            self.fail("Unsupported native bridge operation.")

        def apply(state):
            identity = request.get("identity")
            if not isinstance(identity, dict):
                self.fail("Exact native bridge identity is required.")
            self.api["canonical_uuid"](identity.get("nodeId"), "bridge worker ID")
            node = state["nodes"].get(identity.get("nodeId"))
            native = node.get("nativeMessaging") if node else None
            credential = request.get("credential")
            if (
                not native or self.identity(node) != identity or node.get("archiving")
                or node["phase"] != "turn-running" or not isinstance(credential, str)
                or not self.api["process_matches"](node)
                or len(credential) != 64
                or any(char not in "0123456789abcdef" for char in credential)
                or not secrets.compare_digest(native["credentialHash"],
                                              hashlib.sha256(credential.encode()).hexdigest())
            ):
                self.fail("Native bridge credential or exact session identity is invalid.")
            registration = self.api["canonical_uuid"](request.get("registration"), "registration")
            if operation == "register" and node.get("providerProcess") is None:
                return {"status": "starting"}
            if not self.api["native_bridge_caller_matches"](node):
                self.fail("Bridge caller is not a child of the exact bound provider process.")
            if native["closed"] and operation != "close":
                self.fail("Native adapter registration is permanently closed for this generation.")
            self.maintain(state)
            if operation == "register":
                if native["registration"] not in (None, registration):
                    self.fail("A different adapter already owns this generation; automatic adoption is refused.")
                native["registration"], native["heartbeat"] = registration, self.api["now"]()
                return {"identity": identity}
            if native["registration"] != registration:
                self.fail("Native bridge registration is stale.")
            native["heartbeat"] = self.api["now"]()
            messages = [item for item in state["nativeMessages"] if item["receiver"] == identity]
            if operation == "ready":
                native["ready"] = True
                return {"ready": True}
            if operation == "close":
                # Do not permit a replacement to replay any uncertain turn.
                for item in messages:
                    if item["state"] == "inflight":
                        item["state"] = "unknown"
                native["heartbeat"] = "1970-01-01T00:00:00+00:00"
                native["ready"] = False
                native["closed"] = True
                return {"closed": True}
            if not native["ready"]:
                self.fail("Native adapter has not confirmed its supported SDK session binding.")
            if operation == "poll":
                blocked = set()
                for item in messages:
                    sender = item["sender"]["nodeId"]
                    if item["state"] in {"inflight", "unknown"}:
                        blocked.add(sender)
                    if item["state"] == "queued" and sender not in blocked:
                        item["state"], item["registration"] = "inflight", registration
                        return {"message": item}
                return {"message": None}
            item = next((item for item in messages if item["id"] == request.get("messageId")), None)
            if item is None or item["registration"] != registration:
                self.fail("Message does not belong to this adapter registration.")
            if operation == "expired":
                if (item["state"] not in {"inflight", "unknown"} or item["providerMessageId"] is not None
                        or item["reply"] is not None
                        or self.api["now_date"]() < self.date(item["expiresAt"], "expiry")):
                    self.fail("Only an expired offer that was never sent can be expired by its adapter.")
                item["state"] = "expired"
            elif operation == "unknown":
                if item["state"] == "inflight":
                    item["state"] = "unknown"
            elif operation == "delivered":
                provider_id = self.text(request.get("providerMessageId"), 128)
                if item["providerMessageId"] not in (None, provider_id):
                    self.fail("Conflicting provider acceptance.")
                if item["state"] not in {"inflight", "unknown", "delivered", "acknowledged", "replied"}:
                    self.fail("Message is not in a deliverable state.")
                item["providerMessageId"] = provider_id
                if item["state"] in {"inflight", "unknown"}:
                    item["state"] = "delivered"
            else:
                if item["state"] not in {"inflight", "unknown", "delivered", "acknowledged", "replied"}:
                    self.fail("Message has not been offered to this session.")
                if operation == "reply":
                    body = self.text(request.get("body"), MAX_BODY)
                    digest = hashlib.sha256(body.encode()).hexdigest()
                    if item["replyHash"] not in (None, digest):
                        self.fail("A different explicit reply already exists.")
                    item["replyHash"], item["state"] = digest, "replied"
                    if (self.api["now_date"]() - self.date(item["createdAt"], "creation")).total_seconds() <= RETENTION:
                        item["reply"] = body
                elif item["state"] != "replied":
                    item["state"] = "acknowledged"
            return {"message": item}
        return self.api["mutate"](root, apply)
