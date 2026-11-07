"""Tests of the base agent graph with a fake model (US-LANG-004)."""

import pytest
from ai_engine.graph import build_graph
from ai_engine.nodes import parse_severity
from langchain_core.language_models.fake_chat_models import FakeListChatModel


def test_graph_runs_triage_then_investigator() -> None:
    model = FakeListChatModel(responses=["high", "Possible connection saturation."])
    graph = build_graph(model, context_provider=lambda state: "db: 85% conexiones")

    result = graph.invoke({"ticket_id": "T-1", "description": "La BD responde lento"})

    assert result["severity"] == "high"
    assert result["status"] == "investigated"
    assert len(result["agent_notes"]) == 2
    assert "saturation" in result["agent_notes"][1]
    assert len(result["messages"]) == 2
    assert result["analysis"] == "Possible connection saturation."


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("CRITICAL", "critical"), (" Low.", "low"), ("no idea", "medium")],
)
def test_parse_severity(raw: str, expected: str) -> None:
    assert parse_severity(raw) == expected


def test_compiled_graph_requires_model_env(monkeypatch: pytest.MonkeyPatch) -> None:
    import ai_engine.graph as graph_module

    monkeypatch.delenv("AI_MODEL_NAME", raising=False)
    with pytest.raises(RuntimeError, match="AI_MODEL_NAME"):
        _ = graph_module.compiled_graph  # attribute access builds the graph lazily


_OPENAI_ENV = {"AI_MODEL_NAME": "gpt-4o-mini", "OPENAI_API_KEY": "sk-test"}


def test_build_chat_model_uses_openai_key_and_default_endpoint() -> None:
    from ai_engine.config import build_chat_model

    model = build_chat_model(_OPENAI_ENV)

    assert model.model_name == "gpt-4o-mini"  # type: ignore[attr-defined]
    assert model.openai_api_key.get_secret_value() == "sk-test"  # type: ignore[attr-defined]
    assert model.openai_api_base is None  # type: ignore[attr-defined]


def test_build_chat_model_accepts_custom_base_url() -> None:
    from ai_engine.config import build_chat_model

    model = build_chat_model({**_OPENAI_ENV, "OPENAI_BASE_URL": "https://llm.example/v1"})

    assert model.openai_api_base == "https://llm.example/v1"  # type: ignore[attr-defined]


@pytest.mark.parametrize("missing", ["AI_MODEL_NAME", "OPENAI_API_KEY"])
def test_build_chat_model_requires_each_variable(missing: str) -> None:
    from ai_engine.config import build_chat_model

    env = {k: v for k, v in _OPENAI_ENV.items() if k != missing}
    with pytest.raises(RuntimeError, match=missing):
        build_chat_model(env)
