"""Queue interface. A real deployment adds an adapter for the centre's own system.

No method here takes a priority or a position argument. That is deliberate:
nothing outside the centre rules can reorder the queue.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


class QueueError(Exception):
    code = "queue_error"


class TicketNotFound(QueueError):
    code = "ticket_not_found"


class InvalidTransition(QueueError):
    code = "invalid_transition"


class TicketExpired(QueueError):
    code = "ticket_expired"


class VisitNotEligible(QueueError):
    code = "visit_not_eligible"


class VisitHasLiveTicket(QueueError):
    code = "visit_has_live_ticket"


class CounterBusy(QueueError):
    code = "counter_busy"


@dataclass(frozen=True)
class Ticket:
    id: str
    visit_id: str | None
    counter_id: str
    centre_id: str
    number: str | None
    seq: int | None
    priority: int
    state: str
    simulated: bool
    call_count: int
    reserved_at: str | None
    activated_at: str | None
    called_at: str | None
    done_at: str | None
    released_at: str | None


@dataclass(frozen=True)
class CallResult:
    called: Ticket | None
    auto_completed: list[Ticket]


@dataclass(frozen=True)
class Position:
    ticket_id: str
    state: str
    number: str | None
    people_ahead: int | None
    est_wait_min: int | None
    expires_at: str | None


class QueueAdapter(ABC):
    @abstractmethod
    def issue_ticket(self, visit_id: str, counter_id: str) -> Ticket:
        """Reserve remotely. A reserved ticket has no number and no place."""

    @abstractmethod
    def activate(self, ticket_id: str, method: str = "button") -> Ticket:
        """Patient arrived: assign the number and join the end of the queue."""

    @abstractmethod
    def call_next(self, counter_id: str) -> CallResult:
        """Call the next patient at this counter."""

    @abstractmethod
    def serve(self, ticket_id: str) -> Ticket:
        """Called patient reached the counter."""

    @abstractmethod
    def no_show(self, ticket_id: str) -> Ticket:
        """Called patient did not come. Back to active."""

    @abstractmethod
    def complete(self, ticket_id: str) -> Ticket:
        """Finish this stage's ticket."""

    @abstractmethod
    def advance(self, ticket_id: str, next_counter_id: str) -> Ticket:
        """Finish this ticket and join the next stage's queue, in one step."""

    @abstractmethod
    def finish_visit(self, ticket_id: str) -> Ticket:
        """Finish this ticket and complete the visit, in one step."""

    @abstractmethod
    def issue_active(self, visit_id: str, counter_id: str) -> Ticket:
        """Create a ticket that joins the end of the queue now."""

    @abstractmethod
    def release(self, ticket_id: str, reason: str) -> Ticket:
        """Remove a live ticket from the queue."""

    @abstractmethod
    def escalate(self, ticket_id: str, reason: str) -> Ticket:
        """Release a live ticket and send the visit to emergency, in one step."""

    @abstractmethod
    def complete_simulated(self, counter_id: str) -> Ticket | None:
        """Finish the first simulated ticket here, if any. Never a real one."""

    @abstractmethod
    def expire_due(self) -> list[Ticket]:
        """Release every reserved ticket past its check-in window."""

    @abstractmethod
    def position(self, ticket_id: str) -> Position:
        """Where this ticket stands now."""

    @abstractmethod
    def live_ticket(self, visit_id: str) -> Ticket | None:
        """The visit's reserved, active, called or serving ticket, if any."""

    @abstractmethod
    def latest_ticket(self, visit_id: str) -> Ticket | None:
        """The visit's most recent ticket, in any state."""

    @abstractmethod
    def queue_snapshot(self, counter_id: str) -> list[dict]:
        """The counter's queue: called and serving first, then active in order."""
