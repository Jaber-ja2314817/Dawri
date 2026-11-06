"""The shared API layer: error shapes, the SPA fallback, day resets and dependencies."""

from __future__ import annotations

import math

import pytest
from fastapi import Depends
from fastapi.testclient import TestClient
from pydantic import BaseModel

from backend import auth, bootstrap, config, db, deps, geo, main, timeutil, views
from backend.adapters.queue_base import Ticket
from backend.ai.asr import (
    ASR_UNAVAILABLE_AR,
    ASR_UNAVAILABLE_EN,
    AsrBadAudio,
    AsrFailed,
    AsrUnavailable,
)
from backend.ai.handoff import HandoffError
from backend.ai.session import SessionError
from backend.deps import ApiError
from backend.main import app
from backend.simulate import SIMULATED_TICKETS
from backend.tests import api_helpers
from backend.tests.api_helpers import (
    DESK,
    DOCTOR2,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    bearer,
    patient_token,
    staff_token,
)
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"


class Arrive(BaseModel):
    lat: float
    lng: float


@pytest.fixture
def add_route():
    saved = list(app.router.routes)

    def add(*args, **kwargs):
        app.add_api_route(*args, **kwargs)
        # A stub sharing a real route's path has to match first.
        app.router.routes.insert(0, app.router.routes.pop())

    yield add
    app.router.routes[:] = saved


@pytest.fixture
def conn(api):  # The app's own startup has seeded this database.
    connection = db.connect()
    yield connection
    connection.close()


def _boom(error):
    def route():
        raise error

    return route


def _body_is_exact(response, status, **expected):
    assert response.status_code == status
    assert response.json() == expected


# Request validation


def test_a_nan_body_is_a_422_not_a_500(api, add_route):
    def arrive(body: Arrive) -> dict:
        return {}

    add_route("/api/test-nan", arrive, methods=["POST"])
    response = api.post(
        "/api/test-nan",
        content='{"lat":NaN}',
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_request"
    assert set(response.json()) == {"error", "message"}


def test_validation_never_echoes_the_input(api, add_route):
    def arrive(body: Arrive) -> dict:
        return {}

    add_route("/api/test-echo", arrive, methods=["POST"])
    words = "my secret complaint"
    for body in ({"lat": words, "lng": 1}, {"lat": 1, words: 2}, [words]):
        response = api.post("/api/test-echo", json=body)
        assert response.status_code == 422
        assert words not in response.text
        assert set(response.json()) == {"error", "message"}


def test_malformed_json_is_invalid_request(api, add_route):
    def arrive(body: Arrive) -> dict:
        return {}

    add_route("/api/test-json", arrive, methods=["POST"])
    response = api.post(
        "/api/test-json", content="{not json", headers={"Content-Type": "application/json"}
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_request"
    assert "not json" not in response.text


def test_a_bad_query_value_is_invalid_request(api, add_route):
    def route(lat: float) -> dict:
        return {}

    add_route("/api/test-query", route)
    response = api.get("/api/test-query", params={"lat": "my secret"})
    assert response.status_code == 422
    assert "my secret" not in response.text


# Mapped errors


@pytest.mark.parametrize(
    ("code", "status"),
    [
        ("visit_not_found", 404),
        ("invalid_text", 422),
        ("visit_not_in_intake", 409),
        ("visit_not_deflected", 409),
        ("anything_else", 400),
    ],
)
def test_session_errors(api, add_route, code, status):
    add_route("/api/test-session", _boom(SessionError(code)))
    response = api.get("/api/test-session")
    assert response.status_code == status
    assert response.json()["error"] == code
    assert set(response.json()) == {"error", "message"}


@pytest.mark.parametrize(("code", "status"), [("no_intake", 409), ("no_patient", 404)])
def test_handoff_errors(api, add_route, code, status):
    add_route("/api/test-handoff", _boom(HandoffError(code)))
    response = api.get("/api/test-handoff")
    assert response.status_code == status
    assert response.json()["error"] == code
    assert set(response.json()) == {"error", "message"}


def test_asr_unavailable_speaks_both_languages(api, add_route):
    add_route("/api/test-asr", _boom(AsrUnavailable(ASR_UNAVAILABLE_EN)))
    _body_is_exact(
        api.get("/api/test-asr"),
        503,
        error="asr_unavailable",
        message=ASR_UNAVAILABLE_EN,
        message_ar=ASR_UNAVAILABLE_AR,
    )


def test_asr_bad_audio(api, add_route):
    add_route("/api/test-asr", _boom(AsrBadAudio("Audio must be a WAV file.")))
    response = api.get("/api/test-asr")
    assert response.status_code == 400
    assert response.json()["error"] == "bad_audio"


def test_asr_failed_hides_the_provider_text(api, add_route):
    add_route("/api/test-asr", _boom(AsrFailed("provider said something private")))
    response = api.get("/api/test-asr")
    assert response.status_code == 502
    assert response.json()["error"] == "asr_failed"
    assert "private" not in response.text


def test_api_error_merges_its_extras(api, add_route):
    add_route("/api/test-extra", _boom(ApiError(409, "too_far", "Too far.", distance_m=200)))
    _body_is_exact(
        api.get("/api/test-extra"), 409, error="too_far", message="Too far.", distance_m=200
    )


def test_an_api_error_with_no_extras_keeps_its_shape(api, add_route):
    add_route("/api/test-plain", _boom(ApiError(418, "teapot", "Short and stout.")))
    _body_is_exact(api.get("/api/test-plain"), 418, error="teapot", message="Short and stout.")


def test_an_unexpected_error_is_json_and_hides_the_detail(api_env, add_route):
    add_route("/api/test-crash", _boom(RuntimeError("secret detail")))
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/api/test-crash")
    assert response.status_code == 500
    assert response.json()["error"] == "internal_error"
    assert "secret detail" not in response.text


def test_health_keeps_its_exact_shape(api):
    assert api.get("/api/health").json() == {
        "status": "ok",
        "ai_mode": "simulated",
        "simulate_load": True,
    }


# SPA


@pytest.fixture
def built(tmp_path, monkeypatch):
    root = tmp_path / "dist"
    (root / "assets").mkdir(parents=True)
    (root / "index.html").write_text("<!doctype html><title>Dawri</title>", encoding="utf-8")
    (root / "assets" / "app.js").write_text("console.log('app')", encoding="utf-8")
    (tmp_path / "secret.txt").write_text("outside the build", encoding="utf-8")
    sibling = tmp_path / "dist-secret"
    sibling.mkdir()
    (sibling / "secret.txt").write_text("outside the build", encoding="utf-8")
    monkeypatch.setenv("DAWRI_STATIC_DIR", str(root))
    return root


def _is_index(response):
    assert response.status_code == 200
    assert response.text.startswith("<!doctype html>")
    assert response.headers["cache-control"] == "no-cache"


@pytest.mark.parametrize("path", ["/", "/staff/nurse", "/patient/visit/V123", "/index.html"])
def test_app_paths_get_the_index(api, built, path):
    _is_index(api.get(path))


def test_a_real_asset_returns_itself(api, built):
    response = api.get("/assets/app.js")
    assert response.status_code == 200
    assert response.text == "console.log('app')"
    assert "javascript" in response.headers["content-type"]
    assert response.headers.get("cache-control") != "no-cache"


def test_a_missing_asset_falls_back_to_the_index(api, built):
    _is_index(api.get("/assets/missing.js"))


def test_head_works_like_get(api, built):
    response = api.head("/staff/nurse")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-cache"
    assert response.content == b""


@pytest.mark.parametrize(
    "path",
    [
        "/%2e%2e/secret.txt",
        "/%2e%2e%2fsecret.txt",
        "/..%2fsecret.txt",
        "/assets/%2e%2e/%2e%2e/secret.txt",
        "/%2e%2e/dist-secret/secret.txt",  # Shares a prefix with the build folder.
        "//etc/passwd",
        "/%2fetc%2fpasswd",
        "/link/secret.txt",
        "/%00",
        "/assets/app.js%00.txt",
        "/" + "a" * 5000,
    ],
)
def test_a_traversal_never_leaks_a_file(api, built, path):
    (built / "link").symlink_to(built.parent)
    response = api.get(path)
    assert "outside the build" not in response.text
    assert "root:" not in response.text
    _is_index(response)


def test_the_build_folder_may_sit_behind_a_symlink(api, built, tmp_path, monkeypatch):
    alias = tmp_path / "alias"
    alias.symlink_to(built)
    monkeypatch.setenv("DAWRI_STATIC_DIR", str(alias))
    assert api.get("/assets/app.js").text == "console.log('app')"


def test_unknown_api_path_is_json(api, built):
    response = api.get("/api/unknown")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert set(response.json()) == {"error", "message"}


def test_wrong_method_stays_json_with_its_allow_header(api, built):
    response = api.post("/api/health")
    assert response.status_code == 405
    assert response.json()["error"] == "method_not_allowed"
    assert "GET" in response.headers["allow"]


def test_post_to_a_page_path_is_a_json_404(api, built):
    response = api.post("/staff/nurse")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


def test_docs_still_work(api, built):
    response = api.get("/docs")
    assert response.status_code == 200
    assert "swagger" in response.text.lower()
    assert api.get("/openapi.json").json()["info"]["title"] == "Dawri"


def test_a_route_added_after_startup_still_wins(api, built, add_route):
    add_route("/late-route", lambda: {"late": True})
    assert api.get("/late-route").json() == {"late": True}


def test_no_build_is_a_json_404(api, tmp_path, monkeypatch):
    monkeypatch.setenv("DAWRI_STATIC_DIR", str(tmp_path / "nothing-here"))
    for path in ("/", "/staff/nurse"):
        response = api.get(path)
        assert response.status_code == 404
        assert response.json()["error"] == "frontend_not_built"
        assert set(response.json()) == {"error", "message"}


def test_api_paths_are_unaffected_by_no_build(api, tmp_path, monkeypatch):
    monkeypatch.setenv("DAWRI_STATIC_DIR", str(tmp_path / "nothing-here"))
    assert api.get("/api/unknown").json()["error"] == "not_found"


def test_static_dir_uses_the_override(monkeypatch, tmp_path):
    monkeypatch.setenv("DAWRI_STATIC_DIR", str(tmp_path))
    assert config.static_dir() == tmp_path


def test_static_dir_prefers_the_image_copy(monkeypatch, tmp_path):
    monkeypatch.delenv("DAWRI_STATIC_DIR", raising=False)
    monkeypatch.setattr(config, "_REPO_ROOT", tmp_path)
    assert config.static_dir() == tmp_path / "frontend" / "dist"
    (tmp_path / "backend" / "static").mkdir(parents=True)
    assert config.static_dir() == tmp_path / "backend" / "static"


def test_env_example_lists_the_static_dir_blank():
    root = config._REPO_ROOT
    lines = (root / ".env.example").read_text(encoding="utf-8").splitlines()
    assert "DAWRI_STATIC_DIR=" in lines
    assert "HF_TOKEN=" in lines


# Startup across days


TOTAL_SIMULATED = sum(SIMULATED_TICKETS.values())


def _count(conn, table):
    return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def _age_database(conn, day="2026-01-01"):
    conn.execute("UPDATE number_sequence SET day = ?", (day,))


@pytest.fixture
def startup_env(api_env):
    bootstrap.startup()
    connection = db.connect()
    yield connection
    connection.close()


def test_a_database_from_an_earlier_day_is_reset(startup_env):
    conn = startup_env
    token = auth.create_session(conn, "staff", NURSE)
    make_visit(conn, "P001")
    conn.execute("UPDATE ticket SET state = 'done'")
    _age_database(conn)

    bootstrap.startup()

    today = timeutil.doha_day(timeutil.utcnow())
    days = {row["day"] for row in conn.execute("SELECT day FROM number_sequence").fetchall()}
    assert days == {today}
    assert _count(conn, "visit") == 0
    assert _count(conn, "ticket") == TOTAL_SIMULATED
    waiting = conn.execute("SELECT COUNT(*) FROM ticket WHERE state = 'active'").fetchone()[0]
    assert waiting == TOTAL_SIMULATED
    assert auth.lookup_session(conn, token) is not None


def test_a_reset_on_startup_restores_t014(api_env):
    with TestClient(app):
        pass
    conn = db.connect()
    make_visit(conn, "P001")
    _age_database(conn)
    with TestClient(app) as client:
        engine = app.state.engine
        ticket = engine.activate(engine.issue_ticket(make_visit(conn, "P001"), T1).id)
        assert ticket.number == "T-014"
        assert client.get("/api/health").status_code == 200
    conn.close()


def test_a_stale_reset_takes_the_load_argument(api_env):
    bootstrap.startup(simulate_load=True)
    conn = db.connect()
    _age_database(conn)
    bootstrap.startup(simulate_load=False)
    assert _count(conn, "ticket") == 0
    conn.close()


def test_a_same_day_restart_keeps_everything(api_env):
    with TestClient(app):
        pass
    conn = db.connect()
    visit_id = make_visit(conn, "P001")
    token = auth.create_session(conn, "staff", NURSE)
    rows = [tuple(row) for row in conn.execute("SELECT * FROM ticket").fetchall()]
    with TestClient(app):
        pass
    assert [tuple(row) for row in conn.execute("SELECT * FROM ticket").fetchall()] == rows
    assert _count(conn, "visit") == 1
    assert conn.execute("SELECT id FROM visit").fetchone()["id"] == visit_id
    assert auth.lookup_session(conn, token) is not None
    conn.close()


def test_an_empty_database_seeds_once_not_twice(api_env, monkeypatch):
    resets = []
    monkeypatch.setattr(bootstrap, "reset_demo", lambda load=None: resets.append(load))
    bootstrap.startup()
    assert resets == []


# Geo


def test_distance_of_a_point_to_itself_is_zero():
    assert geo.distance_m(25.17302, 51.59575, 25.17302, 51.59575) == 0


def test_one_degree_of_latitude():
    assert geo.distance_m(25.0, 51.0, 26.0, 51.0) == pytest.approx(111_195, abs=10)


def test_longitude_shrinks_with_latitude():
    assert geo.distance_m(25.0, 51.0, 25.0, 52.0) == pytest.approx(
        111_195 * math.cos(math.radians(25)), abs=10
    )


def test_distance_is_symmetric():
    there = geo.distance_m(25.17302, 51.59575, 25.2558, 51.55778)
    back = geo.distance_m(25.2558, 51.55778, 25.17302, 51.59575)
    assert there == pytest.approx(back)


def test_wakra_to_airport_is_about_ten_km():
    assert 9_000 < geo.distance_m(25.17302, 51.59575, 25.2558, 51.55778) < 11_000


def test_antipodes_do_not_raise():
    assert geo.distance_m(0, 0, 0, 180) == pytest.approx(math.pi * 6_371_000, abs=1)


# Dependencies


def _add_dep_route(add_route, dependency):
    def route(value=Depends(dependency)) -> dict:
        return dict(value)

    add_route("/api/test-dep/{visit_id}", route)


def _add_counter_route(add_route, dependency):
    def route(value=Depends(dependency)) -> dict:
        return dict(value)

    add_route("/api/test-counter/{counter_id}", route)


def test_staff_member_has_the_contract_fields(api, add_route):
    def route(staff: dict = Depends(deps.staff_member)) -> dict:
        return staff

    add_route("/api/test-staff", route)
    token = staff_token(api, NURSE)
    body = api.get("/api/test-staff", headers=bearer(token)).json()
    assert set(body) == {"id", "name", "role", "clinic", "centre_id"}
    assert body["id"] == NURSE
    assert body["centre_id"] == "C-WAKRA"


def test_staff_member_refuses_a_patient_and_no_token(api, add_route):
    def route(staff: dict = Depends(deps.staff_member)) -> dict:
        return staff

    add_route("/api/test-staff", route)
    assert api.get("/api/test-staff").status_code == 401
    token = patient_token(api, FATIMA_QID)
    assert api.get("/api/test-staff", headers=bearer(token)).status_code == 403


def test_require_role(api, add_route):
    def route(staff: dict = Depends(deps.require_role("nurse", "desk"))) -> dict:
        return staff

    add_route("/api/test-role", route)
    for staff_id, status in ((NURSE, 200), (DESK, 200), (DOCTOR2, 403), (PHARMACIST, 403)):
        response = api.get("/api/test-role", headers=bearer(staff_token(api, staff_id)))
        assert response.status_code == status, staff_id
        if status == 403:
            assert response.json()["error"] == "wrong_role"
        else:
            assert response.json()["id"] == staff_id


def test_load_visit_and_counter_refuse_unknown_ids(conn):
    with pytest.raises(ApiError) as visit_error:
        deps.load_visit(conn, "V-NOPE")
    assert (visit_error.value.status_code, visit_error.value.code) == (404, "visit_not_found")
    with pytest.raises(ApiError) as counter_error:
        deps.load_counter(conn, "C-NOPE")
    assert (counter_error.value.status_code, counter_error.value.code) == (
        404,
        "unknown_counter",
    )


def test_patient_visit_access(api, conn, add_route):
    _add_dep_route(add_route, deps.patient_visit)
    fatima = patient_token(api, FATIMA_QID)
    ravi = patient_token(api, api_helpers.RAVI_QID)
    own = make_visit(conn, "P001")
    child = make_visit(conn, "P004")  # P004 is Fatima's dependent.
    booked = make_visit(conn, "P002", booked_by="P003")

    def status(visit_id, token):
        return api.get(f"/api/test-dep/{visit_id}", headers=bearer(token)).status_code

    assert status(own, fatima) == 200
    assert status(child, fatima) == 200
    assert status(booked, ravi) == 200
    assert status(own, ravi) == 403
    assert status(child, ravi) == 403
    assert status(booked, fatima) == 403
    assert status("V-NOPE", fatima) == 404
    response = api.get(f"/api/test-dep/{own}", headers=bearer(ravi))
    assert response.json()["error"] == "forbidden"
    assert api.get(f"/api/test-dep/{own}").status_code == 401
    assert status(own, staff_token(api, NURSE)) == 403


def test_staff_visit_is_limited_to_the_centre(api, conn, add_route):
    _add_dep_route(add_route, deps.staff_visit)
    visit_id = make_visit(conn, "P001")
    conn.execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", (visit_id,))
    other = make_visit(conn, "P002")  # In intake, so at no centre yet.
    wakra = staff_token(api, NURSE)
    rayyan = staff_token(api, "S-RAY-NURSE1")

    assert api.get(f"/api/test-dep/{visit_id}", headers=bearer(wakra)).status_code == 200
    response = api.get(f"/api/test-dep/{visit_id}", headers=bearer(rayyan))
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"
    assert api.get(f"/api/test-dep/{other}", headers=bearer(wakra)).status_code == 403
    assert api.get("/api/test-dep/V-NOPE", headers=bearer(wakra)).status_code == 404


def test_centre_counter_allows_any_counter_at_the_centre(api, add_route):
    _add_counter_route(add_route, deps.centre_counter)
    token = staff_token(api, PHARMACIST)
    assert api.get(f"/api/test-counter/{T1}", headers=bearer(token)).status_code == 200
    other = api.get("/api/test-counter/C-RAYYAN-T1", headers=bearer(token))
    assert other.status_code == 403
    assert other.json()["error"] == "wrong_centre"
    missing = api.get("/api/test-counter/C-NOPE", headers=bearer(token))
    assert missing.status_code == 404
    assert missing.json()["error"] == "unknown_counter"


def test_own_counter_allows_only_the_counters_staff_member(api, add_route):
    _add_counter_route(add_route, deps.own_counter)
    nurse = staff_token(api, NURSE)
    assert api.get(f"/api/test-counter/{T1}", headers=bearer(nurse)).status_code == 200
    colleague = api.get(f"/api/test-counter/{T1}", headers=bearer(staff_token(api, PHARMACIST)))
    assert colleague.status_code == 403
    assert colleague.json()["error"] == "not_your_counter"
    assert api.get("/api/test-counter/C-NOPE", headers=bearer(nurse)).status_code == 404


# Views


TICKET_VIEW_KEYS = {
    "id",
    "visit_id",
    "number",
    "state",
    "centre_id",
    "counter_id",
    "counter",
    "counter_ar",
    "people_ahead",
    "est_wait_min",
    "expires_at",
}


def test_ticket_view_of_a_reserved_ticket_has_no_number_or_place(api, conn):
    engine = app.state.engine
    ticket: Ticket = engine.issue_ticket(make_visit(conn, "P001"), T1)
    view = views.ticket_view(engine, conn, ticket)
    assert set(view) == TICKET_VIEW_KEYS
    assert view["state"] == "reserved"
    assert view["number"] is None
    assert view["people_ahead"] is None
    assert view["est_wait_min"] is None
    assert view["expires_at"] is not None
    assert view["counter"] == "Triage 1"
    assert view["counter_ar"] == "الفرز 1"


def test_ticket_view_of_an_active_ticket(api, conn):
    engine = app.state.engine
    ticket = engine.issue_active(make_visit(conn, "P001"), T1)
    view = views.ticket_view(engine, conn, ticket)
    assert set(view) == TICKET_VIEW_KEYS
    assert view["number"] == "T-014"
    assert view["people_ahead"] == 3
    assert view["est_wait_min"] == 12
    assert view["expires_at"] is None
    assert view["id"] == ticket.id
    assert view["visit_id"] == ticket.visit_id


def test_ticket_view_reports_the_state_now_not_the_stale_ticket(api, conn):
    engine = app.state.engine
    ticket = engine.issue_active(make_visit(conn, "P001"), T1)
    engine.call_next(T1)
    view = views.ticket_view(engine, conn, ticket)  # `ticket` still says active.
    assert view["state"] == "called"
    assert view["people_ahead"] == 0


# The runtime seam and the helpers


def test_main_keeps_the_runtime_seam(api_env, monkeypatch):
    built_runtime = main.runtime.build_runtime()
    monkeypatch.setattr(main.runtime, "build_runtime", lambda: built_runtime)
    with TestClient(app):
        assert app.state.ai is built_runtime


def test_start_visit_helper(api, add_route):
    calls = []

    def route(body: dict) -> dict:
        calls.append(body)
        return {"visit_id": "V1"}

    add_route("/api/visits", route, methods=["POST"])
    assert api_helpers.start_visit(api, "token") == "V1"
    assert api_helpers.start_visit(api, "token", "P004") == "V1"
    assert calls == [{"consent": True}, {"consent": True, "patient_id": "P004"}]


def test_say_helper_returns_the_last_reply(api, add_route):
    def route(visit_id: str, body: dict) -> dict:
        return {"echo": body["text"], "visit": visit_id}

    add_route("/api/visits/{visit_id}/chat", route, methods=["POST"])
    assert api_helpers.say(api, "token", "V1", "one", "two") == {"echo": "two", "visit": "V1"}


def test_helper_constants_match_the_seed(api):
    for qid in (api_helpers.FATIMA_QID, api_helpers.AHMED_QID, api_helpers.RAVI_QID):
        assert patient_token(api, qid)
    for staff_id in (NURSE, DOCTOR2, PHARMACIST, DESK):
        assert staff_token(api, staff_id)
