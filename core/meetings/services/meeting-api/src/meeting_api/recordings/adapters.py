"""Production adapters — the real ``Storage`` (MinIO/S3) + ``RecordingRepo`` (SQLAlchemy).

Thin translations of the ports to the concrete clients, as the parent's
``recordings.internal_upload_recording`` (storage upload + the ``SELECT ... FOR UPDATE`` row lock on
``meeting.data``) and ``recording_finalizer`` (master build + upload) do. They carry NO test logic.

Heavy imports (boto3/minio, SQLAlchemy) are LAZY (inside the methods / ``build_production_router``)
so the package imports + unit-tests with the in-memory fakes without those runtime deps in the gate
venv — which is why ``pyproject.toml`` needs no extra pins.
"""
from __future__ import annotations

import os
from typing import Optional


class S3Storage:
    """``Storage`` over an S3/MinIO bucket (boto3). Lazy client so the package imports without boto3."""

    def __init__(self, *, bucket: str, endpoint_url: Optional[str] = None,
                 access_key: Optional[str] = None, secret_key: Optional[str] = None):
        self._bucket = bucket
        self._endpoint = endpoint_url
        self._access_key = access_key
        self._secret_key = secret_key
        self._client = None

    def _c(self):
        if self._client is None:
            import boto3

            self._client = boto3.client(
                "s3", endpoint_url=self._endpoint,
                aws_access_key_id=self._access_key, aws_secret_access_key=self._secret_key,
            )
        return self._client

    async def _run(self, fn, *args, **kwargs):
        """Run a BLOCKING boto3 call off the event loop (G4). boto3 is synchronous; calling it directly
        inside an async method stalls the whole control plane (a multi-MB master finalize fetches many
        objects). ``asyncio.to_thread`` offloads it to the default thread pool so the loop keeps serving
        lifecycle/webhook/ws traffic. Overridable in tests."""
        import asyncio

        return await asyncio.to_thread(fn, *args, **kwargs)

    async def upload(self, key: str, data: bytes, *, content_type: str) -> None:
        await self._run(self._c().put_object, Bucket=self._bucket, Key=key, Body=data, ContentType=content_type)

    async def list(self, prefix: str) -> list[str]:
        resp = await self._run(self._c().list_objects_v2, Bucket=self._bucket, Prefix=prefix)
        return sorted(o["Key"] for o in resp.get("Contents", []))

    async def get(self, key: str) -> bytes:
        obj = await self._run(self._c().get_object, Bucket=self._bucket, Key=key)
        return await self._run(obj["Body"].read)

    async def size(self, key: str) -> int:
        head = await self._run(self._c().head_object, Bucket=self._bucket, Key=key)
        return int(head["ContentLength"])

    async def get_range(self, key: str, start: int, end: int) -> bytes:
        # Pass the byte range through to S3 (inclusive offsets) so we fetch only the requested window.
        resp = await self._run(self._c().get_object, Bucket=self._bucket, Key=key, Range=f"bytes={start}-{end}")
        return await self._run(resp["Body"].read)

    async def exists(self, key: str) -> bool:
        from botocore.exceptions import ClientError

        try:
            await self._run(self._c().head_object, Bucket=self._bucket, Key=key)
            return True
        except ClientError:
            return False


class AzureBlobStorage:
    """``Storage`` over an Azure Blob container (``azure-storage-blob``). Lazy client + a sync SDK
    offloaded via ``_run`` (same shape as ``S3Storage`` — see its docstring for the G4 rationale);
    kept as a second ``Storage`` implementation so ``STORAGE_BACKEND`` can select either at deploy
    time with zero changes to ``service.py``/``router.py``."""

    def __init__(self, *, container: str, connection_string: str):
        self._container = container
        self._connection_string = connection_string
        self._client = None

    def _c(self):
        if self._client is None:
            from azure.storage.blob import BlobServiceClient

            service = BlobServiceClient.from_connection_string(self._connection_string)
            self._client = service.get_container_client(self._container)
        return self._client

    async def _run(self, fn, *args, **kwargs):
        """Run a BLOCKING azure-storage-blob call off the event loop — same reasoning as
        ``S3Storage._run`` (G4): the SDK's sync client does blocking I/O."""
        import asyncio

        return await asyncio.to_thread(fn, *args, **kwargs)

    async def upload(self, key: str, data: bytes, *, content_type: str) -> None:
        from azure.storage.blob import ContentSettings

        await self._run(
            self._c().upload_blob, name=key, data=data, overwrite=True,
            content_settings=ContentSettings(content_type=content_type),
        )

    async def list(self, prefix: str) -> list[str]:
        def _list():
            return sorted(b.name for b in self._c().list_blobs(name_starts_with=prefix))

        return await self._run(_list)

    async def get(self, key: str) -> bytes:
        def _get():
            return self._c().get_blob_client(key).download_blob().readall()

        return await self._run(_get)

    async def size(self, key: str) -> int:
        def _size():
            return self._c().get_blob_client(key).get_blob_properties().size

        return await self._run(_size)

    async def get_range(self, key: str, start: int, end: int) -> bytes:
        # Azure's `length` is a byte COUNT from `offset` — unlike S3's inclusive Range header, so
        # convert the inclusive [start, end] this Protocol method receives into offset/length.
        def _get_range():
            return (
                self._c().get_blob_client(key)
                .download_blob(offset=start, length=end - start + 1)
                .readall()
            )

        return await self._run(_get_range)

    async def exists(self, key: str) -> bool:
        def _exists():
            return self._c().get_blob_client(key).exists()

        return await self._run(_exists)


def _minio_endpoint_url() -> str:
    """Build an http(s) MinIO URL from MINIO_ENDPOINT (host:port) + MINIO_SECURE, mirroring 0.11."""
    endpoint = os.getenv("MINIO_ENDPOINT", "minio:9000")
    if endpoint.startswith("http://") or endpoint.startswith("https://"):
        return endpoint
    scheme = "https" if os.getenv("MINIO_SECURE", "false").lower() == "true" else "http"
    return f"{scheme}://{endpoint}"


def build_storage_from_env() -> "S3Storage | AzureBlobStorage":
    """Selects the recordings object-storage backend from ``STORAGE_BACKEND`` (default ``minio``) —
    the ONE construction site both ``__main__.build_production_app`` and ``build_production_router``
    call. Replaces two previously-hardcoded ``S3Storage(...)`` blocks that disagreed on default
    bucket name and which env vars they honored; the MinIO branch here preserves the
    ``build_production_app`` behavior exactly (its fallback chain is the one kept)."""
    backend = os.getenv("STORAGE_BACKEND", "minio").strip().lower()
    if backend in ("azure_blob", "azure"):
        return AzureBlobStorage(
            container=os.getenv("AZURE_STORAGE_CONTAINER", "vexa"),
            connection_string=os.getenv("AZURE_STORAGE_CONNECTION_STRING", ""),
        )
    return S3Storage(
        bucket=os.getenv("MINIO_BUCKET", os.getenv("RECORDING_BUCKET", "vexa")),
        endpoint_url=os.getenv("S3_ENDPOINT") or _minio_endpoint_url(),
        access_key=os.getenv("S3_ACCESS_KEY") or os.getenv("MINIO_ACCESS_KEY"),
        secret_key=os.getenv("S3_SECRET_KEY") or os.getenv("MINIO_SECRET_KEY"),
    )


class SqlAlchemyRecordingRepo:
    """``RecordingRepo`` over a SQLAlchemy-async ``session_factory`` (``meetings`` /
    ``meeting_sessions``; recordings live in ``meetings.data`` JSONB)."""

    def __init__(self, session_factory):
        self._session_factory = session_factory

    async def find_session(self, session_uid):
        from sqlalchemy import select

        from ..sessions.models import MeetingSession

        async with self._session_factory() as db:
            s = (
                await db.execute(
                    select(MeetingSession).where(MeetingSession.session_uid == session_uid)
                )
            ).scalars().first()
            return {"meeting_id": s.meeting_id, "session_uid": s.session_uid} if s else None

    async def _meeting(self, db, meeting_id):
        from sqlalchemy import select

        from ..sessions.models import Meeting

        return (
            await db.execute(select(Meeting).where(Meeting.id == meeting_id).with_for_update())
        ).scalars().first()

    async def get_recordings(self, meeting_id):
        async with self._session_factory() as db:
            m = await self._meeting(db, meeting_id)
            data = m.data if isinstance(m.data, dict) else {}
            return list(data.get("recordings", []))

    async def put_recordings(self, meeting_id, recordings):
        from sqlalchemy.orm.attributes import flag_modified

        async with self._session_factory() as db:
            m = await self._meeting(db, meeting_id)
            data = dict(m.data) if isinstance(m.data, dict) else {}
            data["recordings"] = list(recordings)
            m.data = data
            flag_modified(m, "data")
            await db.commit()

    async def mutate_recordings(self, meeting_id, mutator):
        """Atomic read→modify→write under ONE ``SELECT … FOR UPDATE`` row lock (G3). The lock spans the
        whole mutation (held from the read through commit), so concurrent chunk-upload / finalize calls
        serialize instead of clobbering each other (the old get+put released the lock between)."""
        from sqlalchemy.orm.attributes import flag_modified

        async with self._session_factory() as db:
            m = await self._meeting(db, meeting_id)  # SELECT … FOR UPDATE
            data = dict(m.data) if isinstance(m.data, dict) else {}
            recordings = list(data.get("recordings", []))
            new_recordings, result = mutator(recordings)
            data["recordings"] = list(new_recordings)
            m.data = data
            flag_modified(m, "data")
            await db.commit()
            return result

    async def owner_of(self, meeting_id):
        from sqlalchemy import select

        from ..sessions.models import Meeting

        async with self._session_factory() as db:
            m = (await db.execute(select(Meeting).where(Meeting.id == meeting_id))).scalars().first()
            return m.user_id if m else None

    async def list_meeting_recordings(self, user_id):
        from sqlalchemy import select

        from ..sessions.models import Meeting

        async with self._session_factory() as db:
            rows = (
                await db.execute(select(Meeting).where(Meeting.user_id == user_id))
            ).scalars().all()
            out = []
            for m in rows:
                data = m.data if isinstance(m.data, dict) else {}
                for r in data.get("recordings", []):
                    out.append({**r, "meeting_id": m.id})
            return out


def build_production_router(*, database_url: Optional[str] = None):
    """Construct the recordings router with real MinIO/S3 + SQLAlchemy adapters from env."""
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from ..db import build_engine
    from .router import build_router

    database_url = database_url or os.getenv(
        "DATABASE_URL", "postgresql+asyncpg://postgres:postgres@postgres:5432/vexa"
    )
    engine = build_engine(database_url)  # #635: env-steered pool
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    storage = build_storage_from_env()
    return build_router(SqlAlchemyRecordingRepo(session_factory), storage)
