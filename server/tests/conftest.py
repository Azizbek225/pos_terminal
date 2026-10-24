import pytest


@pytest.fixture(autouse=True)
def _reset_globals():
    """Login urinishlari va Tailscale holati testlar orasida o'tib ketmasin."""
    from . import test_sync  # noqa: F401 — muhit o'zgaruvchilari app'dan oldin
    from app import funnel, web

    web._failed.clear()
    funnel._cache = None
    funnel._job.clear()
    yield
    if funnel._job.get("proc") is not None:
        funnel._job["proc"].kill()
    funnel._job.clear()
    funnel._cache = None
