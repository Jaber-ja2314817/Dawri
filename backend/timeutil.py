"""Time helpers. Stored timestamps are UTC; the working day is Doha's."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

DOHA = timezone(timedelta(hours=3))


def _aware(dt: datetime) -> datetime:
    """Treat a naive datetime as UTC, so nothing depends on the machine's zone."""
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    """UTC string with fixed-width microseconds, so lexical order is time order."""
    return _aware(dt).astimezone(timezone.utc).isoformat(timespec="microseconds")


def parse(s: str) -> datetime:
    return _aware(datetime.fromisoformat(s))


def doha_day(dt: datetime) -> str:
    return _aware(dt).astimezone(DOHA).date().isoformat()


def age_on(dob: str, dt: datetime | date) -> int:
    """Whole years on the Doha date of dt. A plain date is taken as that date."""
    born = date.fromisoformat(dob)
    today = date.fromisoformat(doha_day(dt)) if isinstance(dt, datetime) else dt
    return today.year - born.year - ((today.month, today.day) < (born.month, born.day))
