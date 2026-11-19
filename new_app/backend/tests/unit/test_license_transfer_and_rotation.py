"""Phase L2-E — transfer-by-reissue and key rotation through the real manager.

The audit's section 7 transfer lifecycle and section 12 L2 exit criteria
require two scenarios no existing test exercises end-to-end:

* **transfer by reissue** — a second install becomes licensed by the owner
  reissuing for ITS request while the first install keeps its own license
  (no revocation channel exists), and neither code activates on the other
  machine;
* **key-id rotation** — one verification file carrying two generations
  verifies codes from both through ``LicenseManager.activate``, and a code
  signed by an unlisted key fails closed with ``license_invalid_key``.

Both run through the real generator (strict ``SMPr1`` parse -> issue ->
merge export -> manager activate), not hand-built payloads.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidKeyError,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.state_store import StateStore
from app.licensing.trial import TrialManager
from app.licensing.verification_keys import load_verification_keys
from tools.license_generator import generator, keystore

UTC = timezone.utc
T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)

PC1_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-transfer-pc1",
    system_volume_serial="SERIAL-TRANSFER-1",
    hostname="pc1-transfer",
)
PC2_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-transfer-pc2",
    system_volume_serial="SERIAL-TRANSFER-2",
    hostname="pc2-transfer",
)


@dataclass
class Clock:
    moment: datetime = T0

    def __call__(self) -> datetime:
        return self.moment


@dataclass
class Install:
    """One simulated PC: its own state dir, store, trial and manager."""

    provider: StaticHardwareInfoProvider
    state_dir: Path
    store: StateStore
    clock: Clock
    trial: TrialManager

    @property
    def fingerprint(self) -> str:
        return HardwareFingerprintService(self.provider).fingerprint()

    def manager(self, keys_path: Path) -> LicenseManager:
        return LicenseManager(
            state_dir=self.state_dir,
            store=self.store,
            keys_path=keys_path,
            fingerprint=HardwareFingerprintService(self.provider),
            clock=self.clock,
            trial=self.trial,
        )


def make_install(tmp_path: Path, name: str, provider: StaticHardwareInfoProvider) -> Install:
    state_dir = tmp_path / name / "data" / "license"
    store = StateStore(state_dir, use_dpapi=False)
    clock = Clock()
    trial = TrialManager(state_dir=state_dir, store=store, clock=clock)
    return Install(
        provider=provider,
        state_dir=state_dir,
        store=store,
        clock=clock,
        trial=trial,
    )


def owner_keys(tmp_path: Path) -> tuple[Path, Path]:
    """One keystore with k1, one verification file carrying k1."""
    key_dir = tmp_path / "owner_keys"
    public = keystore.generate_keypair(key_dir, "k1")
    keys_file = tmp_path / "verification_keys.json"
    keystore.merge_verification_keys(keys_file, keystore.public_entry("k1", public))
    return key_dir, keys_file


def issue_for(install: Install, keys_path: Path, key_dir: Path, *, key_id: str = "k1"):
    install.trial.ensure_started()
    request = install.manager(keys_path).build_activation_request().request_code
    return generator.issue_license(request, key_id=key_id, key_dir=key_dir)


class TestTransferByReissue:
    def test_a_second_machine_licenses_by_reissue_and_the_first_stays_licensed(
        self, tmp_path: Path
    ) -> None:
        key_dir, keys_file = owner_keys(tmp_path)
        pc1 = make_install(tmp_path, "pc1", PC1_PROVIDER)
        pc2 = make_install(tmp_path, "pc2", PC2_PROVIDER)

        pc1.trial.ensure_started()
        pc2.trial.ensure_started()
        request1 = pc1.manager(keys_file).build_activation_request()
        request2 = pc2.manager(keys_file).build_activation_request()

        # Distinct hardware is the whole point of a transfer: the audit's
        # section 7 reissue flow exists because fingerprints differ.  The
        # manager never exposes raw fields, so read them back through the
        # generator's strict SMPr1 parser.
        parsed1 = generator.parse_request_code(request1.request_code)
        parsed2 = generator.parse_request_code(request2.request_code)
        assert parsed1.hw_hash == pc1.fingerprint
        assert parsed2.hw_hash == pc2.fingerprint
        assert parsed1.hw_hash != parsed2.hw_hash
        assert parsed1.install_id != parsed2.install_id

        issued1 = generator.issue_license(
            request1.request_code, key_id="k1", key_dir=key_dir
        )
        issued2 = generator.issue_license(
            request2.request_code, key_id="k1", key_dir=key_dir
        )
        assert issued1.license_id != issued2.license_id

        status1 = pc1.manager(keys_file).activate(issued1.code)
        status2 = pc2.manager(keys_file).activate(issued2.code)
        assert status1.mode == "lifetime"
        assert status2.mode == "lifetime"
        assert status1.license_id == issued1.license_id
        assert status2.license_id == issued2.license_id

        # No revocation channel exists (audit section 7.5): licensing PC2
        # must leave PC1 exactly as it was.
        assert pc1.manager(keys_file).status().license_id == issued1.license_id

        # Neither code activates on the other machine.
        with pytest.raises(LicenseBoundElsewhereError) as pc1_rejects:
            pc1.manager(keys_file).activate(issued2.code)
        assert pc1_rejects.value.code == "license_bound_elsewhere"
        with pytest.raises(LicenseBoundElsewhereError):
            pc2.manager(keys_file).activate(issued1.code)

        # The rejected attempts changed nothing on either machine.
        assert pc1.manager(keys_file).status().license_id == issued1.license_id
        assert pc2.manager(keys_file).status().license_id == issued2.license_id


class TestKeyRotationThroughManager:
    def test_codes_from_both_generations_verify_through_one_keys_file(
        self, tmp_path: Path
    ) -> None:
        key_dir = tmp_path / "owner_keys"
        public1 = keystore.generate_keypair(key_dir, "k1")
        public2 = keystore.generate_keypair(key_dir, "k2")
        keys_file = tmp_path / "verification_keys.json"
        keystore.merge_verification_keys(keys_file, keystore.public_entry("k1", public1))
        keystore.merge_verification_keys(keys_file, keystore.public_entry("k2", public2))
        assert set(load_verification_keys(keys_file)) == {"k1", "k2"}

        old_machine = make_install(tmp_path, "pc1", PC1_PROVIDER)
        new_machine = make_install(tmp_path, "pc2", PC2_PROVIDER)

        old_code = issue_for(old_machine, keys_file, key_dir, key_id="k1")
        new_code = issue_for(new_machine, keys_file, key_dir, key_id="k2")

        old_status = old_machine.manager(keys_file).activate(old_code.code)
        new_status = new_machine.manager(keys_file).activate(new_code.code)

        # Rotation keeps both generations verifiable through the SAME
        # verification file - the exit criterion the generator-level
        # rotation test alone does not pin.
        assert old_status.mode == "lifetime"
        assert old_status.key_id == "k1"
        assert new_status.mode == "lifetime"
        assert new_status.key_id == "k2"
        assert old_machine.manager(keys_file).status().key_id == "k1"
        assert new_machine.manager(keys_file).status().key_id == "k2"

    def test_a_code_signed_by_an_unlisted_key_fails_closed_then_recovers(
        self, tmp_path: Path
    ) -> None:
        key_dir = tmp_path / "owner_keys"
        keystore.generate_keypair(key_dir, "k1")
        public2 = keystore.generate_keypair(key_dir, "k2")
        # The installed verification file carries only the NEW generation:
        # an old-generation code must fail closed, not fall back.
        keys_file = tmp_path / "verification_keys.json"
        keystore.merge_verification_keys(keys_file, keystore.public_entry("k2", public2))

        machine = make_install(tmp_path, "pc1", PC1_PROVIDER)
        machine.trial.ensure_started()

        stale = generator.issue_license(
            machine.manager(keys_file).build_activation_request().request_code,
            key_id="k1",
            key_dir=key_dir,
        )
        with pytest.raises(LicenseInvalidKeyError) as rejected:
            machine.manager(keys_file).activate(stale.code)
        assert rejected.value.code == "license_invalid_key"
        assert machine.manager(keys_file).status() is None

        # The same install recovers with a listed key: rotation is additive,
        # not a dead end.
        current = generator.issue_license(
            machine.manager(keys_file).build_activation_request().request_code,
            key_id="k2",
            key_dir=key_dir,
        )
        status = machine.manager(keys_file).activate(current.code)
        assert status.mode == "lifetime"
        assert status.key_id == "k2"
