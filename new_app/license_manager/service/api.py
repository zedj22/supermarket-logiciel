"""FastAPI application for the KlickPOS License Manager.

Every route is administrator-only and lives under ``/v1``; there is no public
surface beyond ``/healthz``.  The browser never talks to Firestore and never
receives signing material: it holds a Firebase ID token, and every activation
code it displays came from an audited call to this service.

Error contract (stable, documented in ``README.md``)::

    {"error": {"code": "snake_case_code", "message": "...", "details": {...}}}

No provider message, key material, activation code or hardware identifier is
ever included in an error body or a log line.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

import structlog
from fastapi import Depends, FastAPI, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from service.auth import AdminPrincipal, authenticate_admin
from service.cloud_logging import configure_logging
from service.cloud_run import SERVICE_IDENTITY_HEADER, ServiceIdentityVerifier
from service.container import LazyContainer, ServiceContainer
from service.contracts import DeviceRecord, LicenseRecord
from service.errors import ApiError
from service.limits import BodyLimitMiddleware, SlidingWindowLimiter, enforce
from service.service import (
    EXISTING_LICENSE_NOTICE,
    REVOCATION_NOTICE,
    REVOKED_CODE_WARNING,
    LicenseService,
)
from service.settings import Settings, load_settings

logger = structlog.get_logger(__name__)

__all__ = ["app", "create_app"]


# --------------------------------------------------------------------------- #
# Request bodies (strict: an unknown field is a 422, never silently dropped)
# --------------------------------------------------------------------------- #


class _StrictRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CustomerInput(_StrictRequest):
    name: str = Field(min_length=1, max_length=200)
    email: str | None = Field(default=None, max_length=254)
    phone: str | None = Field(default=None, max_length=40)
    notes: str | None = Field(default=None, max_length=2000)


class ParseRequestBody(_StrictRequest):
    request_code: str = Field(min_length=1, max_length=512)


class IssueRequestBody(_StrictRequest):
    request_code: str | None = Field(default=None, min_length=1, max_length=512)
    hw_hash: str | None = Field(default=None, min_length=64, max_length=64)
    features: list[str] = Field(default_factory=lambda: ["pos"])
    customer_id: str | None = Field(default=None, max_length=64)
    customer: CustomerInput | None = None

    @field_validator("request_code", "hw_hash", "customer_id")
    @classmethod
    def _blank_is_none(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None


class ReissueRequestBody(_StrictRequest):
    reason: str = Field(min_length=4, max_length=1000)
    confirm: bool = False


class RevokeRequestBody(_StrictRequest):
    reason: str = Field(min_length=4, max_length=1000)


# --------------------------------------------------------------------------- #
# Responses
# --------------------------------------------------------------------------- #


class LicenseSummary(BaseModel):
    license_id: str
    hw_hash: str
    status: str
    kind: str
    key_id: str
    issued_at: datetime
    created_at: datetime
    created_by: str
    features: list[str]
    customer_id: str | None = None
    install_id: str | None = None
    reissued_from: str | None = None
    superseded_by: str | None = None
    revoked_at: datetime | None = None
    revoked_reason: str | None = None


class LicenseDetail(LicenseSummary):
    """A summary plus the activation code (only ever over an audited call)."""

    activation_code: str


class DeviceSummary(BaseModel):
    hw_hash: str
    fingerprint_display_code: str | None = None
    install_id: str | None = None
    request_code: str | None = None
    customer_id: str | None = None
    current_license_id: str | None = None
    first_seen_at: datetime | None = None
    last_seen_at: datetime | None = None


class ParseResponse(BaseModel):
    hw_hash: str
    install_id: str
    requested_at: datetime
    fingerprint_display_code: str
    existing_license: LicenseSummary | None = None
    device: DeviceSummary | None = None


class IssueResponse(BaseModel):
    created: bool
    license: LicenseDetail
    notice: str | None = None


class DeviceResponse(BaseModel):
    device: DeviceSummary
    licenses: list[LicenseSummary]
    notices: list[str] = Field(default_factory=list)


class CodeResponse(BaseModel):
    license_id: str
    hw_hash: str
    status: str
    activation_code: str
    warning: str | None = None


class ReissueResponse(BaseModel):
    previous: LicenseSummary
    license: LicenseDetail
    notice: str


class RevokeResponse(BaseModel):
    license: LicenseSummary
    notice: str


class HealthResponse(BaseModel):
    status: Literal["ok"]
    environment: str


# -- dashboard read models (never carry an activation code) ---------------- #


class AuditEntry(BaseModel):
    event_id: str
    at: datetime
    action: str
    actor_uid: str
    actor_email: str | None = None
    license_id: str | None = None
    hw_hash: str | None = None
    client_ip: str | None = None
    details: dict[str, Any] = Field(default_factory=dict)


class CustomerSummary(BaseModel):
    customer_id: str
    name: str | None = None
    email: str | None = None
    phone: str | None = None
    notes: str | None = None
    updated_at: datetime | None = None


class OverviewCounts(BaseModel):
    customers: int = 0
    devices: int = 0
    active_licenses: int = 0
    revoked_licenses: int = 0
    superseded_licenses: int = 0


class OverviewResponse(BaseModel):
    counts: OverviewCounts
    recent_licenses: list[LicenseSummary]
    recent_events: list[AuditEntry]


class DeviceListItem(BaseModel):
    device: DeviceSummary
    current_license: LicenseSummary | None = None


class DeviceListResponse(BaseModel):
    items: list[DeviceListItem]
    total: int


class LicenseListResponse(BaseModel):
    items: list[LicenseSummary]
    total: int


class CustomerListResponse(BaseModel):
    items: list[CustomerSummary]
    total: int


class CustomerDetailResponse(BaseModel):
    customer: CustomerSummary
    devices: list[DeviceSummary]
    licenses: list[LicenseSummary]


class AuditListResponse(BaseModel):
    items: list[AuditEntry]
    total: int


# --------------------------------------------------------------------------- #
# Mapping helpers
# --------------------------------------------------------------------------- #


def _summary(record: LicenseRecord) -> LicenseSummary:
    return LicenseSummary(
        license_id=record.license_id,
        hw_hash=record.hw_hash,
        status=record.status,
        kind=record.kind,
        key_id=record.key_id,
        issued_at=record.issued_at,
        created_at=record.created_at,
        created_by=record.created_by,
        features=list(record.features),
        customer_id=record.customer_id,
        install_id=record.install_id,
        reissued_from=record.reissued_from,
        superseded_by=record.superseded_by,
        revoked_at=record.revoked_at,
        revoked_reason=record.revoked_reason,
    )


def _detail(record: LicenseRecord) -> LicenseDetail:
    return LicenseDetail(activation_code=record.activation_code, **_summary(record).model_dump())


def _audit_entry(event: Any) -> AuditEntry:
    return AuditEntry(
        event_id=event.event_id,
        at=event.at,
        action=event.action,
        actor_uid=event.actor_uid,
        actor_email=event.actor_email,
        license_id=event.license_id,
        hw_hash=event.hw_hash,
        client_ip=event.client_ip,
        details=dict(event.details or {}),
    )


def _customer_summary(customer_id: str, document: Any) -> CustomerSummary:
    return CustomerSummary(
        customer_id=customer_id,
        name=document.get("name"),
        email=document.get("email"),
        phone=document.get("phone"),
        notes=document.get("notes"),
        updated_at=document.get("updated_at"),
    )


def _device_summary(device: DeviceRecord) -> DeviceSummary:
    return DeviceSummary(
        hw_hash=device.hw_hash,
        fingerprint_display_code=device.fingerprint_display_code,
        install_id=device.install_id,
        request_code=device.request_code,
        customer_id=device.customer_id,
        current_license_id=device.current_license_id,
        first_seen_at=device.first_seen_at,
        last_seen_at=device.last_seen_at,
    )


# --------------------------------------------------------------------------- #
# Error envelope
# --------------------------------------------------------------------------- #


def _error_body(code: str, message: str, details: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "details": details or {}}}


def _install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        headers = {"Cache-Control": "no-store", **exc.headers}
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(exc.code, exc.message, exc.details),
            headers=headers,
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = sorted(
            ".".join(str(part) for part in error.get("loc", ()) if part != "body")
            for error in exc.errors()
        )
        return JSONResponse(
            status_code=422,
            content=_error_body(
                "validation_error",
                "the request body does not match the documented shape",
                {"fields": [field for field in fields if field]},
            ),
            headers={"Cache-Control": "no-store"},
        )

    @app.exception_handler(Exception)
    async def _unexpected(_: Request, exc: Exception) -> JSONResponse:
        # Class name only: a provider message could carry infrastructure detail.
        logger.error("license_api_unhandled_error", reason=type(exc).__name__)
        return JSONResponse(
            status_code=500,
            content=_error_body("internal_error", "the request could not be completed"),
            headers={"Cache-Control": "no-store"},
        )


# --------------------------------------------------------------------------- #
# Application factory
# --------------------------------------------------------------------------- #


def _client_ip(request: Request) -> str | None:
    """The caller's address, for the audit trail.

    ``X-Forwarded-For`` is honoured only when the deployment declares a
    trusted proxy (``LICENSE_API_TRUST_PROXY=1``).  Otherwise any caller with a
    valid administrator token could write a forged address into the audit log,
    which is exactly the record an investigation would rely on.
    """
    settings = getattr(request.app.state, "settings", None)
    forwarded = request.headers.get("x-forwarded-for")
    if settings is not None and settings.trust_proxy:
        if forwarded:
            return forwarded.split(",")[0].strip() or None
        return request.client.host if request.client else None
    if forwarded:
        # A forwarded header arrived and this deployment was not told to trust
        # it.  ``request.client`` may already have been rewritten from that same
        # header by the ASGI server (uvicorn's ``--proxy-headers`` trusts
        # loopback by default), so it is no longer evidence either: record no
        # address rather than a value the caller could have chosen.
        return None
    return request.client.host if request.client else None


def create_app(
    *,
    settings: Settings | None = None,
    container: ServiceContainer | LazyContainer | None = None,
) -> FastAPI:
    """Build the License API (production wiring by default)."""
    resolved = settings or load_settings()
    # Staging isolation (Phase 8.4.3): validate the staging key file here, at
    # application construction — import time for `uvicorn service.api:app` — so
    # a missing or malformed staging keys mount fails the deployment instead of
    # surfacing as a 503 on the first issuance.  Production does not enable the
    # flag, so nothing changes there.
    if resolved.require_staging_keys:
        from service.staging_keys import ensure_staging_keys

        ensure_staging_keys(resolved)
    # Staging signing-key match (Phase 8.4.4): the keys file cannot tell us
    # whether the *private* seed belongs to it.  With the flag on, derive the
    # public half from the mounted seed and compare it with the published key
    # for the staging id, so a seed copied from another keypair crashes the
    # start instead of signing codes no staging client can verify.  Off by
    # default: production's lazy first-use fetch is untouched.
    if resolved.require_signing_key_match:
        from service.signing_key_match import ensure_signing_key_matches

        ensure_signing_key_matches(resolved)
    configure_logging()
    app = FastAPI(
        title="KlickPOS License Manager API",
        version="1.0.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.container = container or LazyContainer(resolved)
    app.state.settings = resolved
    # Cloud Run IAM is the outer gate; this verifier repeats the check inside
    # the process (see service/cloud_run.py).  ``None`` means the deployment
    # does not use service-to-service authentication — only ever true for a
    # local run or an explicitly configured non-Cloud-Run install.
    app.state.service_identity = (
        ServiceIdentityVerifier(
            resolved.cloud_run_audience, resolved.cloud_run_invoker_emails
        )
        if resolved.require_cloud_run_invoker
        else None
    )
    app.state.read_limiter = SlidingWindowLimiter(resolved.rate_limit_per_minute)
    app.state.issue_limiter = SlidingWindowLimiter(resolved.issue_rate_limit_per_minute)

    _install_error_handlers(app)
    app.add_middleware(BodyLimitMiddleware, max_bytes=resolved.max_body_bytes)

    @app.middleware("http")
    async def _no_store(request: Request, call_next):
        """Activation codes are bearer material: never cache an API answer."""
        response = await call_next(request)
        if request.url.path.startswith("/v1"):
            response.headers["Cache-Control"] = "no-store"
        return response

    def _resolve(request: Request) -> ServiceContainer:
        holder = request.app.state.container
        return holder.get() if isinstance(holder, LazyContainer) else holder

    def _actor(request: Request) -> AdminPrincipal:
        # Authentication never builds the repository: a bad token is a 401 even
        # if the cloud configuration is incomplete.
        holder = request.app.state.container
        # 1. Is the *caller service* the Dashboard we expect?  Cloud Run IAM
        #    already enforced this at the edge; verifying the same Google token
        #    here means a loosened IAM binding is still fail-closed.
        caller = request.app.state.service_identity
        if caller is not None:
            caller.check(request.headers.get(SERVICE_IDENTITY_HEADER))
        # 2. Is the *administrator* signed in, allowlisted (and, if required,
        #    presenting a valid App Check token)?
        return authenticate_admin(
            authorization=request.headers.get("authorization"),
            app_check_header=request.headers.get("x-firebase-appcheck"),
            verifier=holder.verifier,
            settings=request.app.state.settings,
        )

    def _service(request: Request) -> LicenseService:
        return _resolve(request).service

    # -- health -------------------------------------------------------- #
    @app.get("/healthz", response_model=HealthResponse, tags=["ops"])
    async def healthz() -> HealthResponse:
        return HealthResponse(status="ok", environment=resolved.env)

    # -- 1. parse ------------------------------------------------------ #
    @app.post(
        "/v1/requests/parse",
        response_model=ParseResponse,
        tags=["license"],
        summary="Parse an SMPr1 activation request",
    )
    async def parse_request(
        body: ParseRequestBody,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> ParseResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        result = service.parse(
            principal, body.request_code, client_ip=_client_ip(request)
        )
        return ParseResponse(
            hw_hash=result.hw_hash,
            install_id=result.install_id,
            requested_at=result.requested_at,
            fingerprint_display_code=result.fingerprint_display_code,
            existing_license=(
                _summary(result.existing_license)
                if result.existing_license is not None
                else None
            ),
            device=_device_summary(result.device) if result.device is not None else None,
        )

    # -- 2. issue ------------------------------------------------------ #
    @app.post(
        "/v1/licenses",
        response_model=IssueResponse,
        status_code=201,
        tags=["license"],
        summary="Create the single lifetime license for a fingerprint",
    )
    async def create_license(
        body: IssueRequestBody,
        request: Request,
        response: Response,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> IssueResponse:
        enforce(request.app.state.issue_limiter, principal.uid)
        outcome = service.issue(
            principal,
            request_code=body.request_code,
            hw_hash=body.hw_hash,
            features=body.features,
            customer_id=body.customer_id,
            customer=body.customer.model_dump() if body.customer else None,
            client_ip=_client_ip(request),
        )
        # An existing license is not a creation: answer 200 with the original.
        response.status_code = 201 if outcome.created else 200
        notice: str | None = None
        if not outcome.created:
            notice = EXISTING_LICENSE_NOTICE
            if outcome.license.status == "revoked":
                # The rule is "never mint a second license", so a revoked one is
                # returned too — but never without saying that it is revoked.
                notice = f"{EXISTING_LICENSE_NOTICE} {REVOKED_CODE_WARNING}"
        return IssueResponse(
            created=outcome.created,
            license=_detail(outcome.license),
            notice=notice,
        )

    # -- 3. device ----------------------------------------------------- #
    @app.get(
        "/v1/devices/{hw_hash}",
        response_model=DeviceResponse,
        tags=["license"],
        summary="Existing device and its licenses",
    )
    async def get_device(
        hw_hash: str,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> DeviceResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        device, licenses = service.get_device(
            principal, hw_hash, client_ip=_client_ip(request)
        )
        notices: list[str] = []
        if any(record.status == "revoked" for record in licenses):
            notices.append(REVOCATION_NOTICE)
        return DeviceResponse(
            device=_device_summary(device),
            licenses=[_summary(record) for record in licenses],
            notices=notices,
        )

    # -- 4. code retrieval --------------------------------------------- #
    @app.get(
        "/v1/licenses/{license_id}/code",
        response_model=CodeResponse,
        tags=["license"],
        summary="Retrieve the original activation code (audited)",
    )
    async def get_license_code(
        license_id: str,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> CodeResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        record = service.get_code(
            principal, license_id, client_ip=_client_ip(request)
        )
        return CodeResponse(
            license_id=record.license_id,
            hw_hash=record.hw_hash,
            status=record.status,
            activation_code=record.activation_code,
            warning=REVOKED_CODE_WARNING if record.status == "revoked" else None,
        )

    # -- 5. reissue ---------------------------------------------------- #
    @app.post(
        "/v1/licenses/{license_id}/reissue",
        response_model=ReissueResponse,
        tags=["license"],
        summary="Issue a replacement license, keeping the original record",
    )
    async def reissue_license(
        license_id: str,
        body: ReissueRequestBody,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> ReissueResponse:
        enforce(request.app.state.issue_limiter, principal.uid)
        superseded, issued = service.reissue(
            principal,
            license_id,
            reason=body.reason,
            confirm=body.confirm,
            client_ip=_client_ip(request),
        )
        return ReissueResponse(
            previous=_summary(superseded),
            license=_detail(issued),
            notice=(
                "The previous license is preserved with status 'superseded' and "
                "keeps its own audit history. A KlickPOS device keeps whichever "
                "code it last activated: send the new code and have the customer "
                "activate it."
            ),
        )

    # -- 6. revoke ----------------------------------------------------- #
    @app.post(
        "/v1/licenses/{license_id}/revoke",
        response_model=RevokeResponse,
        tags=["license"],
        summary="Record an administrative revocation",
    )
    async def revoke_license(
        license_id: str,
        body: RevokeRequestBody,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> RevokeResponse:
        enforce(request.app.state.issue_limiter, principal.uid)
        record = service.revoke(
            principal, license_id, reason=body.reason, client_ip=_client_ip(request)
        )
        return RevokeResponse(license=_summary(record), notice=REVOCATION_NOTICE)

    # -- 7. dashboard reads -------------------------------------------- #
    # Rationale: the dashboard must list and search devices, licenses,
    # customers and the audit trail, and show totals.  None of that existed:
    # the original API only exposed one device by its exact fingerprint.  These
    # are read-only, administrator-only and never return an activation code.
    @app.get(
        "/v1/overview",
        response_model=OverviewResponse,
        tags=["dashboard"],
        summary="Totals plus recent licenses and recent audit events",
    )
    async def overview(
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> OverviewResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        result = service.overview(principal)
        return OverviewResponse(
            counts=OverviewCounts(**result["counts"]),
            recent_licenses=[_summary(record) for record in result["recent_licenses"]],
            recent_events=[_audit_entry(event) for event in result["recent_events"]],
        )

    @app.get(
        "/v1/devices",
        response_model=DeviceListResponse,
        tags=["dashboard"],
        summary="List or search devices, with their current license",
    )
    async def list_devices(
        request: Request,
        query: str = Query(default="", max_length=200),
        limit: int = Query(default=50, ge=1, le=200),
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> DeviceListResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        rows, total = service.search_devices(principal, query=query, limit=limit)
        return DeviceListResponse(
            items=[
                DeviceListItem(
                    device=_device_summary(device),
                    current_license=_summary(license) if license is not None else None,
                )
                for device, license in rows
            ],
            total=total,
        )

    @app.get(
        "/v1/licenses",
        response_model=LicenseListResponse,
        tags=["dashboard"],
        summary="List or search licenses (never returns activation codes)",
    )
    async def list_licenses(
        request: Request,
        query: str = Query(default="", max_length=200),
        status: str = Query(default="", max_length=20),
        limit: int = Query(default=50, ge=1, le=200),
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> LicenseListResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        records, total = service.search_licenses(
            principal, query=query, status=status.strip().lower(), limit=limit
        )
        return LicenseListResponse(
            items=[_summary(record) for record in records], total=total
        )

    @app.get(
        "/v1/customers",
        response_model=CustomerListResponse,
        tags=["dashboard"],
        summary="List or search customers",
    )
    async def list_customers(
        request: Request,
        query: str = Query(default="", max_length=200),
        limit: int = Query(default=50, ge=1, le=200),
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> CustomerListResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        rows, total = service.search_customers(principal, query=query, limit=limit)
        return CustomerListResponse(
            items=[_customer_summary(customer_id, document) for customer_id, document in rows],
            total=total,
        )

    @app.get(
        "/v1/customers/{customer_id}",
        response_model=CustomerDetailResponse,
        tags=["dashboard"],
        summary="One customer with its devices and licenses",
    )
    async def get_customer(
        customer_id: str,
        request: Request,
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> CustomerDetailResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        document, devices, licenses = service.get_customer(principal, customer_id)
        return CustomerDetailResponse(
            customer=_customer_summary(customer_id, document),
            devices=[_device_summary(device) for device in devices],
            licenses=[_summary(record) for record in licenses],
        )

    @app.get(
        "/v1/audit",
        response_model=AuditListResponse,
        tags=["dashboard"],
        summary="Recent audit events",
    )
    async def list_audit(
        request: Request,
        query: str = Query(default="", max_length=200),
        limit: int = Query(default=100, ge=1, le=200),
        principal: AdminPrincipal = Depends(_actor),
        service: LicenseService = Depends(_service),
    ) -> AuditListResponse:
        enforce(request.app.state.read_limiter, principal.uid)
        events, total = service.search_audit(principal, query=query, limit=limit)
        return AuditListResponse(
            items=[_audit_entry(event) for event in events], total=total
        )

    return app


#: ASGI entry point: ``uvicorn service.api:app``.
app = create_app()
