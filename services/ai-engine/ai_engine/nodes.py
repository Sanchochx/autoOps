"""Graph nodes: Triage and Investigator.

Each node is built by a factory that receives its dependencies (chat model
and, optionally, an MCP context provider), so they can be tested with a fake
model without calling the API.
"""

import logging
from collections.abc import Callable

from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import HumanMessage, SystemMessage

from ai_engine.state import SEVERITIES, AgentState, Severity

logger = logging.getLogger(__name__)

DEFAULT_SEVERITY: Severity = "medium"

TRIAGE_PROMPT = (
    "You are a level 1 SRE triage agent. Classify the severity of the "
    "described incident. Answer with a single word only: "
    "low, medium, high or critical."
)

INVESTIGATOR_PROMPT = (
    "You are an SRE investigator agent. Given an incident description and its "
    "severity, summarize the most likely root cause hypotheses and which "
    "technical information should be checked. Be concise. Always answer in English."
)

# MCP client injection point: receives the state and returns technical
# context (logs, metrics). It will connect to the MCP servers in another US.
ContextProvider = Callable[[AgentState], str]


def parse_severity(raw_text: str) -> Severity:
    """Extract a valid severity from the model text.

    If none is recognizable, uses ``DEFAULT_SEVERITY`` and logs it.
    """
    text = raw_text.strip().lower()
    for severity in SEVERITIES:
        if severity in text:
            return severity
    logger.warning("Unrecognized severity %r; using %s", raw_text, DEFAULT_SEVERITY)
    return DEFAULT_SEVERITY


def make_triage_node(model: BaseChatModel) -> Callable[[AgentState], dict]:
    """Create the triage node that assigns ``severity`` to the ticket."""

    def triage_node(state: AgentState) -> dict:
        response = model.invoke(
            [SystemMessage(content=TRIAGE_PROMPT), HumanMessage(content=state["description"])]
        )
        severity = parse_severity(str(response.content))
        logger.info("Triage ticket=%s severity=%s", state.get("ticket_id"), severity)
        return {
            "severity": severity,
            "status": "triaged",
            "messages": [response],
            "agent_notes": [f"triage: severity assigned = {severity}"],
        }

    return triage_node


def make_investigator_node(
    model: BaseChatModel, context_provider: ContextProvider | None = None
) -> Callable[[AgentState], dict]:
    """Create the investigator node.

    Args:
        model: chat model used to reason about the incident.
        context_provider: optional function that supplies technical context (MCP).
    """

    def investigator_node(state: AgentState) -> dict:
        severity = state.get("severity", DEFAULT_SEVERITY)
        context = context_provider(state) if context_provider else "no technical context"
        response = model.invoke(
            [
                SystemMessage(content=INVESTIGATOR_PROMPT),
                HumanMessage(
                    content=(
                        f"Severity: {severity}\n"
                        f"Incident: {state['description']}\n"
                        f"Technical context: {context}"
                    )
                ),
            ]
        )
        logger.info("Investigation ticket=%s severity=%s", state.get("ticket_id"), severity)
        return {
            "status": "investigated",
            "analysis": str(response.content),
            "messages": [response],
            "agent_notes": [f"investigator: {response.content}"],
        }

    return investigator_node
