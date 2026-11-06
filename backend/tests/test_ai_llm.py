from __future__ import annotations

import inspect
import json
import logging

import httpx
import httpx2
import pytest
from huggingface_hub import InferenceClient, InferenceTimeoutError
from huggingface_hub.errors import HfHubHTTPError

from backend import config
from backend.ai import llm
from backend.tests.ai_fakes import FakeChatClient, mock_transport

DUMMY_TOKEN = "dummy-not-a-real-token"
MESSAGES = [{"role": "user", "content": "عندي حرارة"}]
PATIENT_TEXT = "my private symptom"


@pytest.fixture(autouse=True)
def isolated_env(monkeypatch):
    for name in ("HF_TOKEN", "LLM_MODEL_ID", "LLM_PROVIDER", "LLM_TIMEOUT_SEC"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def recorder(monkeypatch):
    built = []

    class Recorder:
        def __init__(self, **kwargs):
            built.append(kwargs)

    monkeypatch.setattr("huggingface_hub.InferenceClient", Recorder)
    return built


def http_error(status=500):
    request = httpx2.Request("POST", "http://provider.invalid/v1")
    return HfHubHTTPError(
        f"server said {PATIENT_TEXT}", response=httpx2.Response(status, request=request)
    )


def chat_reply(content):
    return {
        "id": "1",
        "object": "chat.completion",
        "created": 1,
        "model": "m",
        "system_fingerprint": "",
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        "choices": [
            {
                "index": 0,
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": content},
            }
        ],
    }


def provider_mapping():
    return {
        "_id": "x",
        "id": config.llm_model_id(),
        "pipeline_tag": "text-generation",
        "inferenceProviderMapping": {
            config.llm_provider(): {
                "providerId": config.llm_model_id(),
                "status": "live",
                "task": "conversational",
            }
        },
    }


def test_the_real_path_sends_the_messages_and_returns_the_content():
    client = FakeChatClient(["  What brings you in today?\n"])
    adapter = llm.build(client=client)

    assert adapter.chat(MESSAGES, max_tokens=50, temperature=0.1) == "What brings you in today?"
    assert client.calls == [{"messages": MESSAGES, "max_tokens": 50, "temperature": 0.1}]


def test_chat_defaults_match_the_vault():
    client = FakeChatClient(["ok"])
    llm.build(client=client).chat(MESSAGES)
    assert client.calls[0]["max_tokens"] == 400
    assert client.calls[0]["temperature"] == 0.2


def test_an_injected_client_is_real_without_a_token():
    assert config.ai_mode() == "simulated"
    adapter = llm.build(client=FakeChatClient([]))
    assert adapter.mode == "real"
    assert adapter.model_id == config.llm_model_id()


def test_the_real_client_accepts_the_exact_call():
    signature = inspect.signature(InferenceClient.chat_completion)
    signature.bind(None, messages=[], max_tokens=1, temperature=0.2)


def test_the_real_client_constructor_accepts_the_exact_arguments():
    inspect.signature(InferenceClient.__init__).bind(
        None, model="m", provider="featherless-ai", token="t", timeout=1.0
    )


def test_the_factory_builds_the_client_from_config(monkeypatch, recorder):
    monkeypatch.setenv("HF_TOKEN", f"  {DUMMY_TOKEN}\n")
    monkeypatch.setenv("LLM_MODEL_ID", "org/other-model")
    monkeypatch.setenv("LLM_PROVIDER", "other-provider")
    monkeypatch.setenv("LLM_TIMEOUT_SEC", "7.5")

    adapter = llm.build()

    assert adapter.mode == "real"
    assert adapter.model_id == "org/other-model"
    assert recorder == [
        {
            "model": "org/other-model",
            "provider": "other-provider",
            "token": DUMMY_TOKEN,
            "timeout": 7.5,
        }
    ]


def test_the_factory_defaults_to_fanar_9b(monkeypatch, recorder):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    llm.build()
    assert recorder[0]["model"] == "QCRI/Fanar-1-9B-Instruct"
    assert recorder[0]["provider"] == "featherless-ai"
    assert recorder[0]["timeout"] == 10.0


def test_a_blank_token_stays_simulated(monkeypatch, recorder):
    monkeypatch.setenv("HF_TOKEN", "   ")
    assert llm.build().mode == "simulated"
    assert recorder == []


def test_simulated_chat_raises_and_builds_no_client(recorder):
    adapter = llm.build()
    assert adapter.mode == "simulated"
    with pytest.raises(llm.LlmUnavailable) as caught:
        adapter.chat(MESSAGES)
    assert caught.value.kind == "unavailable"
    assert isinstance(caught.value, llm.LlmError)
    assert recorder == []


def test_simulated_mode_does_not_claim_a_model():
    assert "Fanar" not in llm.build().model_id


def test_simulated_mode_never_reaches_a_client():
    client = FakeChatClient([])
    with pytest.raises(llm.LlmUnavailable):
        llm.Llm(mode="simulated", model_id="simulated", client=client).chat(MESSAGES)
    assert client.calls == []


@pytest.mark.parametrize(
    "error, kind",
    [
        (TimeoutError("slow"), "timeout"),
        (InferenceTimeoutError("slow"), "timeout"),
        (httpx2.ReadTimeout("slow"), "timeout"),
        (httpx.ReadTimeout("slow"), "timeout"),
        (http_error(), "http"),
        (http_error(404), "http"),
        (httpx2.ConnectError("refused"), "http"),
        (httpx.ConnectError("refused"), "http"),
        (ValueError("odd"), "other"),
        (KeyError("odd"), "other"),
    ],
    ids=lambda value: value if isinstance(value, str) else type(value).__name__,
)
def test_a_failed_call_becomes_an_llm_error_of_the_right_kind(error, kind):
    with pytest.raises(llm.LlmError) as caught:
        llm.build(client=FakeChatClient([error])).chat(MESSAGES)
    assert caught.value.kind == kind


@pytest.mark.parametrize("content", [None, "", "   \n\t "])
def test_no_content_is_kind_empty(content):
    with pytest.raises(llm.LlmError) as caught:
        llm.build(client=FakeChatClient([content])).chat(MESSAGES)
    assert caught.value.kind == "empty"


def test_a_reply_with_no_choices_is_still_an_llm_error():
    class NoChoices(FakeChatClient):
        def chat_completion(self, messages, **kw):
            return type("Reply", (), {"choices": []})()

    with pytest.raises(llm.LlmError):
        llm.build(client=NoChoices([])).chat(MESSAGES)


def test_a_failure_exposes_no_provider_text():
    with pytest.raises(llm.LlmError) as caught:
        llm.build(client=FakeChatClient([http_error()])).chat(MESSAGES)
    assert str(caught.value) == "http"
    # A traceback printed from here must not show the chained provider message.
    assert caught.value.__suppress_context__
    assert caught.value.__cause__ is None


def test_an_unexpected_extra_model_call_fails_the_test_instead_of_falling_back():
    adapter = llm.build(client=FakeChatClient(["only reply"]))
    adapter.chat(MESSAGES)
    with pytest.raises(AssertionError, match="no replies left"):
        adapter.chat(MESSAGES)


def test_slot_keys_are_stripped_and_the_caller_keeps_them():
    client = FakeChatClient(["ok"])
    messages = [
        {"role": "system", "content": "rules", "slot": "system"},
        {"role": "user", "content": "hello", "slot": "duration"},
    ]

    llm.build(client=client).chat(messages)

    assert client.calls[0]["messages"] == [
        {"role": "system", "content": "rules"},
        {"role": "user", "content": "hello"},
    ]
    assert messages[1]["slot"] == "duration"


@pytest.mark.parametrize("reply", [TimeoutError(f"{DUMMY_TOKEN} {PATIENT_TEXT}"), None, "fine"])
def test_nothing_private_reaches_the_log(caplog, reply):
    caplog.set_level(logging.DEBUG)
    adapter = llm.build(client=FakeChatClient([reply]))
    try:
        adapter.chat([{"role": "user", "content": PATIENT_TEXT}])
    except llm.LlmError:
        pass
    assert DUMMY_TOKEN not in caplog.text
    assert PATIENT_TEXT not in caplog.text


def test_a_failure_logs_the_exception_type_and_kind(caplog):
    caplog.set_level(logging.WARNING)
    with pytest.raises(llm.LlmError):
        llm.build(client=FakeChatClient([ValueError("x")])).chat(MESSAGES)
    assert "kind=other" in caplog.text
    assert "ValueError" in caplog.text


def test_the_client_stays_out_of_the_repr():
    assert "client" not in repr(llm.build(client=FakeChatClient([])))


def test_the_adapter_is_frozen():
    with pytest.raises(AttributeError):
        llm.build(client=FakeChatClient([])).mode = "simulated"


def wire_handler(requests):
    def handle(request):
        if request.method == "GET":
            return httpx2.Response(200, json=provider_mapping())
        requests.append(request)
        return httpx2.Response(200, json=chat_reply(" مرحبا "))

    return handle


def test_the_real_client_round_trips_through_the_adapter(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    requests = []

    with mock_transport(wire_handler(requests)):
        reply = llm.build().chat([{"role": "user", "content": "hi", "slot": "x"}], max_tokens=9)

    assert reply == "مرحبا"
    body = json.loads(requests[0].content)
    assert body["messages"] == [{"role": "user", "content": "hi"}]
    assert body["max_tokens"] == 9
    assert body["temperature"] == 0.2
    assert body["model"] == config.llm_model_id()
    assert requests[0].headers["authorization"] == f"Bearer {DUMMY_TOKEN}"


def failing_handler(respond):
    def handle(request):
        if request.method == "GET":
            return httpx2.Response(200, json=provider_mapping())
        return respond(request)

    return handle


def read_timeout(request):
    raise httpx2.ReadTimeout("slow", request=request)


def connect_error(request):
    raise httpx2.ConnectError("refused", request=request)


@pytest.mark.parametrize(
    "respond, kind",
    [
        (read_timeout, "timeout"),
        (connect_error, "http"),
        (lambda request: httpx2.Response(500, text="boom"), "http"),
        (lambda request: httpx2.Response(401, text="no"), "http"),
        (lambda request: httpx2.Response(504, text="slow"), "http"),
        (lambda request: httpx2.Response(200, json=chat_reply(None)), "empty"),
        (lambda request: httpx2.Response(200, json=chat_reply("  ")), "empty"),
    ],
    ids=["read-timeout", "connect", "500", "401", "504", "null-content", "blank-content"],
)
def test_real_client_failures_classify_correctly(monkeypatch, respond, kind):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    with mock_transport(failing_handler(respond)):
        with pytest.raises(llm.LlmError) as caught:
            llm.build().chat(MESSAGES)
    assert caught.value.kind == kind


@pytest.mark.parametrize(
    "value, expected",
    [
        (None, 10.0),
        ("", 10.0),
        ("abc", 10.0),
        ("0", 10.0),
        ("-3", 10.0),
        ("nan", 10.0),
        ("inf", 10.0),
        ("2.5", 2.5),
        (" 12 ", 12.0),
    ],
)
def test_llm_timeout_setting(monkeypatch, value, expected):
    if value is not None:
        monkeypatch.setenv("LLM_TIMEOUT_SEC", value)
    assert config.llm_timeout_sec() == expected


def test_hf_token_setting(monkeypatch):
    assert config.hf_token() == ""
    monkeypatch.setenv("HF_TOKEN", f" {DUMMY_TOKEN} ")
    assert config.hf_token() == DUMMY_TOKEN
