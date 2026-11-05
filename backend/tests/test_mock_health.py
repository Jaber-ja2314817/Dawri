from __future__ import annotations

from datetime import datetime, timezone

from backend import mock_health

ON = datetime(2026, 11, 6, 9, 0, tzinfo=timezone.utc)


def _resources(bundle, resource_type):
    return [
        entry["resource"]
        for entry in bundle["entry"]
        if entry["resource"]["resourceType"] == resource_type
    ]


def test_fatima_has_penicillin_allergy_and_is_34(seeded):
    patient = mock_health.get_patient(seeded, "P001", on=ON)
    assert patient["allergies"] == ["penicillin"]
    assert patient["age"] == 34
    assert patient["full_name_ar"] == "فاطمة التجريبية"
    assert patient["registered_centre"] == {
        "id": "C-WAKRA",
        "name_en": "Al Wakra Health Centre",
        "name_ar": "مركز الوكرة الصحي",
    }
    assert patient["demo"] is True


def test_get_patient_returns_the_flat_fields(seeded):
    assert set(mock_health.get_patient(seeded, "P001", on=ON)) == {
        "id",
        "qid_demo",
        "full_name_en",
        "full_name_ar",
        "dob",
        "age",
        "sex",
        "preferred_lang",
        "allergies",
        "chronic",
        "active_meds",
        "registered_centre",
        "demo",
    }


def test_ahmed_is_67(seeded):
    patient = mock_health.get_patient(seeded, "P002", on=ON)
    assert patient["age"] == 67
    assert patient["chronic"] == ["hypertension"]
    assert patient["active_meds"] == ["amlodipine 5 mg once daily"]


def test_find_by_qid(seeded):
    assert mock_health.find_by_qid(seeded, "DEMO-10002")["id"] == "P002"
    assert mock_health.find_by_qid(seeded, "DEMO-99999") is None


def test_unknown_patient(seeded):
    assert mock_health.get_patient(seeded, "P999") is None
    assert mock_health.get_record(seeded, "P999") is None
    assert mock_health.get_dependents(seeded, "P999") == []


def test_dependents_of_fatima(seeded):
    dependents = mock_health.get_dependents(seeded, "P001", on=ON)
    assert [d["id"] for d in dependents] == ["P004", "P005"]
    assert [d["age"] for d in dependents] == [7, 78]
    assert dependents[1]["registered_centre"]["id"] == "C-WAKRA"


def test_patient_without_dependents(seeded):
    assert mock_health.get_dependents(seeded, "P002") == []


def test_list_demo_patients_excludes_dependents(seeded):
    patients = mock_health.list_demo_patients(seeded)
    assert [p["id"] for p in patients] == ["P001", "P002", "P003", "P006"]
    assert patients[0] == {
        "id": "P001",
        "qid_demo": "DEMO-10001",
        "full_name_en": "Fatima Al-Demo",
        "full_name_ar": "فاطمة التجريبية",
    }


def test_record_for_ahmed(seeded):
    bundle = mock_health.get_record(seeded, "P002")
    assert bundle["resourceType"] == "Bundle"
    assert bundle["type"] == "collection"
    assert bundle["demo"] is True
    assert sorted(e["resource"]["resourceType"] for e in bundle["entry"]) == [
        "Condition",
        "MedicationStatement",
        "Patient",
    ]

    patient = _resources(bundle, "Patient")[0]
    assert patient["identifier"] == [
        {"system": "urn:dawri:demo-qid", "value": "DEMO-10002"}
    ]
    condition = _resources(bundle, "Condition")[0]
    assert condition["subject"] == {"reference": "Patient/P002"}
    assert condition["code"]["text"] == "hypertension"
    medication = _resources(bundle, "MedicationStatement")[0]
    assert medication["status"] == "active"
    assert medication["subject"] == {"reference": "Patient/P002"}


def test_record_for_fatima_has_one_allergy(seeded):
    bundle = mock_health.get_record(seeded, "P001")
    allergies = _resources(bundle, "AllergyIntolerance")
    assert len(allergies) == 1
    assert allergies[0]["patient"] == {"reference": "Patient/P001"}
    assert allergies[0]["code"]["text"] == "penicillin"
    assert _resources(bundle, "Condition") == []
    assert _resources(bundle, "MedicationStatement") == []
