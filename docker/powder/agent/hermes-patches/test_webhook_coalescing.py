import asyncio
import importlib.util
import os
import pathlib
import types
import unittest

MODULE_PATH = pathlib.Path(
    os.environ.get("HERMES_WEBHOOK_MODULE", pathlib.Path(__file__).with_name("webhook.py"))
)
spec = importlib.util.spec_from_file_location("coalesced_webhook", MODULE_PATH)
assert spec is not None
assert spec.loader is not None
webhook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webhook)


class Source:
    def __init__(self, chat_id):
        self.chat_id = chat_id


class Event:
    def __init__(self, chat_id, metadata=None):
        self.source = Source(chat_id)
        self.metadata = metadata or {}


class Runner:
    @staticmethod
    def _session_key_for_source(source):
        return f"key:{source.chat_id}"


def adapter():
    value = object.__new__(webhook.WebhookAdapter)
    value._coalesced_sessions = {}
    value._coalesced_expiry_tasks = {}
    value._coalesced_routes_by_chat_id = {}
    value._silenced_session_chat_ids = set()
    value._active_sessions = {}
    value._pending_messages = {}
    value.gateway_runner = Runner()
    return value


class CoalescingTests(unittest.IsolatedAsyncioTestCase):
    async def test_per_delivery_remains_default(self):
        value = adapter()
        first = value._chat_id_for_delivery("alerts", "one", {}, 1.0)
        second = value._chat_id_for_delivery("alerts", "two", {}, 2.0)
        self.assertNotEqual(first, second)

    async def test_templated_target_disables_coalescing(self):
        value = adapter()
        config = {
            "session_mode": "coalesced",
            "deliver_extra": {"chat_id": "{payload.chat_id}"},
        }
        first = value._chat_id_for_delivery("alerts", "one", config, 1.0)
        second = value._chat_id_for_delivery("alerts", "two", config, 2.0)
        self.assertNotEqual(first, second)
        self.assertEqual(value._coalesced_sessions, {})

    async def test_idle_timeout_is_finite_and_bounded(self):
        self.assertEqual(
            webhook.WebhookAdapter._coalesced_idle_timeout(
                {"session_mode": "coalesced", "session_idle_timeout_seconds": float("inf")}
            ),
            1800.0,
        )
        self.assertEqual(
            webhook.WebhookAdapter._coalesced_idle_timeout(
                {"session_mode": "coalesced", "session_idle_timeout_seconds": 9999999}
            ),
            604800.0,
        )

    async def test_silenced_close_turn_cannot_deliver(self):
        value = adapter()
        chat_id = "webhook:alerts:coalesced:one"
        value._silenced_session_chat_ids.add(chat_id)
        result = await value.send(chat_id, "this must not be delivered")
        self.assertTrue(result.success)

    async def test_coalesced_route_reuses_chat_id_and_cancels_expiry(self):
        value = adapter()
        config = {"session_mode": "coalesced", "session_idle_timeout_seconds": 30}
        first = value._chat_id_for_delivery("alerts", "one", config, 1.0)
        old_task = asyncio.create_task(asyncio.sleep(60))
        value._coalesced_expiry_tasks["alerts"] = old_task
        second = value._chat_id_for_delivery("alerts", "two", config, 2.0)
        await asyncio.sleep(0)
        self.assertEqual(first, second)
        self.assertTrue(old_task.cancelled())

    async def test_idle_expiry_without_close_prompt_ends_session(self):
        value = adapter()
        chat_id = "webhook:alerts:coalesced:one"
        value._coalesced_sessions["alerts"] = {
            "chat_id": chat_id,
            "timeout": 1,
            "close_prompt": None,
        }
        ended = []

        async def fake_end(self, event, session_chat_id, end_reason="webhook_complete"):
            ended.append((session_chat_id, end_reason))

        value._end_webhook_session = types.MethodType(fake_end, value)
        await value._expire_coalesced_session("alerts", Event(chat_id), chat_id, 0)
        self.assertEqual(ended, [(chat_id, "webhook_idle_timeout")])
        self.assertNotIn("alerts", value._coalesced_sessions)

    async def test_idle_expiry_runs_close_prompt_in_same_session(self):
        value = adapter()
        chat_id = "webhook:alerts:coalesced:one"
        value._routes = {"alerts": {"toolsets": ["terminal", "file"]}}
        value._coalesced_sessions["alerts"] = {
            "chat_id": chat_id,
            "timeout": 1,
            "close_prompt": "Create a candidate note; do not modify durable state.",
        }
        received = []
        ended = []

        async def fake_handle(self, event):
            received.append(event)
            key = self.gateway_runner._session_key_for_source(event.source)
            self._active_sessions[key] = asyncio.Event()

        async def fake_end(self, event, session_chat_id, end_reason="webhook_complete"):
            ended.append((session_chat_id, end_reason))

        value.handle_message = types.MethodType(fake_handle, value)
        value._end_webhook_session = types.MethodType(fake_end, value)
        await value._expire_coalesced_session("alerts", Event(chat_id), chat_id, 0)
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0].source.chat_id, chat_id)
        self.assertTrue(received[0].internal)
        self.assertTrue(received[0].metadata["webhook_coalesced_close"])
        self.assertIn(chat_id, value._silenced_session_chat_ids)
        self.assertEqual(
            value.toolsets_for_source(received[0].source), ["session_search"]
        )
        self.assertEqual(ended, [])

    async def test_close_turn_completion_uses_idle_end_reason(self):
        value = adapter()
        calls = []
        chat_id = "webhook:alerts:coalesced:one"
        value._silenced_session_chat_ids.add(chat_id)
        value._coalesced_routes_by_chat_id[chat_id] = "alerts"

        async def fake_end(self, event, session_chat_id, end_reason="webhook_complete"):
            calls.append((session_chat_id, end_reason))

        value._end_webhook_session = types.MethodType(fake_end, value)
        event = Event(
            chat_id,
            {"webhook_coalesced_close": True},
        )
        await value.on_processing_complete(event, None)
        self.assertEqual(
            calls,
            [(chat_id, "webhook_idle_timeout")],
        )
        self.assertNotIn(chat_id, value._silenced_session_chat_ids)
        self.assertNotIn(chat_id, value._coalesced_routes_by_chat_id)

    async def test_colon_route_uses_explicit_reverse_mapping(self):
        value = adapter()
        chat_id = value._chat_id_for_delivery(
            "alerts:prod",
            "one",
            {"session_mode": "coalesced", "session_idle_timeout_seconds": 30},
            1.0,
        )
        scheduled = []

        def fake_schedule(self, route_name, event, session_chat_id):
            scheduled.append((route_name, session_chat_id))

        value._schedule_coalesced_expiry = types.MethodType(fake_schedule, value)
        await value.on_processing_complete(Event(chat_id), None)
        self.assertEqual(scheduled, [("alerts:prod", chat_id)])

    async def test_disconnect_ends_open_coalesced_sessions(self):
        value = adapter()
        chat_id = "webhook:alerts:coalesced:one"
        event = Event(chat_id)
        value._coalesced_sessions["alerts"] = {
            "chat_id": chat_id,
            "event": event,
        }
        value._coalesced_routes_by_chat_id[chat_id] = "alerts"
        value._runner = None
        value._mark_disconnected = lambda: None
        calls = []

        async def fake_end(self, event, session_chat_id, end_reason="webhook_complete"):
            calls.append((session_chat_id, end_reason))

        value._end_webhook_session = types.MethodType(fake_end, value)
        await value.disconnect()
        self.assertEqual(calls, [(chat_id, "webhook_shutdown")])
        self.assertEqual(value._coalesced_sessions, {})
        self.assertEqual(value._coalesced_routes_by_chat_id, {})

    async def test_busy_coalesced_session_merges_and_drains_followups(self):
        config = webhook.PlatformConfig(typing_indicator=False, extra={})
        value = webhook.WebhookAdapter(config)
        route_config = {
            "session_mode": "coalesced",
            "session_idle_timeout_seconds": 60,
        }
        chat_id = value._chat_id_for_delivery(
            "alerts", "one", route_config, 1.0
        )
        value._delivery_info[chat_id] = {"deliver": "log"}
        started = asyncio.Event()
        release = asyncio.Event()
        received = []

        async def handler(event):
            received.append(event.text)
            if len(received) == 1:
                started.set()
                await release.wait()
            return "[SILENT]"

        value._message_handler = handler
        source = value.build_source(
            chat_id=chat_id,
            chat_name="webhook/alerts",
            chat_type="webhook",
            user_id="webhook:alerts",
        )
        first = webhook.MessageEvent(
            text="first",
            source=source,
            metadata={"webhook_coalesced_delivery": True},
            allow_gateway_control=False,
        )
        await value.handle_message(first)
        await asyncio.wait_for(started.wait(), timeout=1)
        self.assertFalse(first.internal)

        for delivery_id, text in (("two", "second"), ("three", "third")):
            same_chat_id = value._chat_id_for_delivery(
                "alerts", delivery_id, route_config, 2.0
            )
            self.assertEqual(same_chat_id, chat_id)
            await value.handle_message(
                webhook.MessageEvent(
                    text=text,
                    source=source,
                    metadata={"webhook_coalesced_delivery": True},
                    allow_gateway_control=False,
                )
            )

        release.set()
        for _ in range(100):
            if len(received) == 2 and not value._active_sessions:
                break
            await asyncio.sleep(0.01)

        self.assertEqual(received, ["first", "second\nthird"])
        for task in value._coalesced_expiry_tasks.values():
            task.cancel()
        await value.cancel_background_tasks()


if __name__ == "__main__":
    unittest.main()
