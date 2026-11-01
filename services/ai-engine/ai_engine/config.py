"""AI engine configuration (Twelve-Factor).

The model and the API key come from environment variables. The client is ``ChatOpenAI``;
``OPENAI_BASE_URL`` (optional) points it at another OpenAI-compatible endpoint.
"""

import os
from collections.abc import Mapping

from langchain_core.language_models.chat_models import BaseChatModel
from langchain_openai import ChatOpenAI

REQUIRED_VARIABLES = ("AI_MODEL_NAME", "OPENAI_API_KEY")


def build_chat_model(env: Mapping[str, str] | None = None) -> BaseChatModel:
    """Build the chat model from the environment.

    Requires ``AI_MODEL_NAME`` and ``OPENAI_API_KEY``. ``OPENAI_BASE_URL`` is optional;
    when empty or unset the client uses the default OpenAI endpoint.

    Args:
        env: variables to read (defaults to ``os.environ``).

    Raises:
        RuntimeError: naming the first required variable that is missing or empty.
    """
    values = os.environ if env is None else env
    for name in REQUIRED_VARIABLES:
        if not values.get(name):
            raise RuntimeError(f"The {name} environment variable is not set")
    return ChatOpenAI(
        model=values["AI_MODEL_NAME"],
        api_key=values["OPENAI_API_KEY"],
        base_url=values.get("OPENAI_BASE_URL") or None,
    )
