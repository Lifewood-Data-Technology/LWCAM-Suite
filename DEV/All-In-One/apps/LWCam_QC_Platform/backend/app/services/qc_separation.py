from __future__ import annotations

import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from app.core.paths import fs_path
from app.services.previews import generate_thumbnail_file


logger = logging.getLogger(__name__)


class SeparationFileError(RuntimeError):
    pass


def child_directory_path(parent: Path, index: int, *, thumbnail: bool = False) -> Path:
    suffix = "_thumbnail_path" if thumbnail else "_path"
    name = parent.name
    if name.endswith(suffix):
        stem = name[: -len(suffix)]
        child_name = f"{stem}_{index:03d}{suffix}"
    else:
        child_name = f"{name}_{index:03d}"
    return parent.with_name(child_name)


@dataclass(frozen=True)
class SeparationGroup:
    index: int
    image_names: tuple[str, ...]
    final_image_dir: Path
    final_thumbnail_dir: Path | None
    temporary_image_dir: Path
    temporary_thumbnail_dir: Path | None


class SeparationFileTransaction:
    """Request-scoped physical split with compensating rollback."""

    def __init__(
        self,
        parent_image_dir: Path,
        parent_thumbnail_dir: Path | None,
        grouped_image_names: list[list[str]],
    ) -> None:
        self.parent_image_dir = parent_image_dir.expanduser().resolve()
        self.parent_thumbnail_dir = (
            parent_thumbnail_dir.expanduser().resolve() if parent_thumbnail_dir else None
        )
        token = uuid4().hex
        self.groups: list[SeparationGroup] = []
        for index, names in enumerate(grouped_image_names, start=1):
            final_image_dir = child_directory_path(self.parent_image_dir, index)
            final_thumbnail_dir = (
                child_directory_path(self.parent_thumbnail_dir, index, thumbnail=True)
                if self.parent_thumbnail_dir
                else None
            )
            self.groups.append(
                SeparationGroup(
                    index=index,
                    image_names=tuple(names),
                    final_image_dir=final_image_dir,
                    final_thumbnail_dir=final_thumbnail_dir,
                    temporary_image_dir=final_image_dir.with_name(
                        f".{final_image_dir.name}.qc_split_{token}.tmp"
                    ),
                    temporary_thumbnail_dir=(
                        final_thumbnail_dir.with_name(
                            f".{final_thumbnail_dir.name}.qc_split_{token}.tmp"
                        )
                        if final_thumbnail_dir
                        else None
                    ),
                )
            )
        self._source_thumbnails: set[str] = set()
        self._applied = False

    def preflight(self) -> None:
        if not fs_path(self.parent_image_dir).is_dir():
            raise SeparationFileError(f"The source image directory does not exist: {self.parent_image_dir}")
        if not os.access(fs_path(self.parent_image_dir), os.W_OK) or not os.access(
            fs_path(self.parent_image_dir.parent), os.W_OK
        ):
            raise SeparationFileError(f"The source image directory is not writable: {self.parent_image_dir}")
        if self.parent_thumbnail_dir:
            if not fs_path(self.parent_thumbnail_dir).is_dir():
                raise SeparationFileError(f"The thumbnail directory does not exist: {self.parent_thumbnail_dir}")
            if not os.access(fs_path(self.parent_thumbnail_dir), os.W_OK) or not os.access(
                fs_path(self.parent_thumbnail_dir.parent), os.W_OK
            ):
                raise SeparationFileError(f"The thumbnail directory is not writable: {self.parent_thumbnail_dir}")

        seen: set[str] = set()
        for group in self.groups:
            for target in (
                group.final_image_dir,
                group.final_thumbnail_dir,
                group.temporary_image_dir,
                group.temporary_thumbnail_dir,
            ):
                if target is not None and fs_path(target).exists():
                    raise SeparationFileError(f"The separation target directory already exists: {target}")
            if not group.image_names:
                raise SeparationFileError("A separated child folder cannot be empty.")
            for image_name in group.image_names:
                if Path(image_name).name != image_name or image_name in {"", ".", ".."}:
                    raise SeparationFileError(f"Invalid image filename: {image_name}")
                if image_name in seen:
                    raise SeparationFileError(f"Image assigned to more than one group: {image_name}")
                seen.add(image_name)
                source = self.parent_image_dir / image_name
                if not fs_path(source).is_file():
                    raise SeparationFileError(f"The source image file does not exist: {source}")
                if self.parent_thumbnail_dir:
                    thumbnail = self.parent_thumbnail_dir / image_name
                    if fs_path(thumbnail).is_file():
                        self._source_thumbnails.add(image_name)

    def apply(self) -> None:
        self.preflight()
        try:
            for group in self.groups:
                fs_path(group.temporary_image_dir).mkdir()
                if group.temporary_thumbnail_dir:
                    fs_path(group.temporary_thumbnail_dir).mkdir()

                for image_name in group.image_names:
                    source = self.parent_image_dir / image_name
                    shutil.move(
                        str(fs_path(source)), str(fs_path(group.temporary_image_dir / image_name))
                    )

                    if not group.temporary_thumbnail_dir or not self.parent_thumbnail_dir:
                        continue
                    source_thumbnail = self.parent_thumbnail_dir / image_name
                    target_thumbnail = group.temporary_thumbnail_dir / image_name
                    if image_name in self._source_thumbnails:
                        shutil.move(str(fs_path(source_thumbnail)), str(fs_path(target_thumbnail)))
                    elif (
                        generate_thumbnail_file(
                            group.temporary_image_dir / image_name,
                            target_thumbnail,
                        )
                        is None
                    ):
                        raise SeparationFileError(f"Thumbnail generation failed: {image_name}")

            for group in self.groups:
                os.replace(fs_path(group.temporary_image_dir), fs_path(group.final_image_dir))
                if group.temporary_thumbnail_dir and group.final_thumbnail_dir:
                    os.replace(
                        fs_path(group.temporary_thumbnail_dir), fs_path(group.final_thumbnail_dir)
                    )
            self._applied = True
        except Exception as error:
            try:
                self.rollback()
            except Exception as rollback_error:
                logger.exception(
                    "QC separation rollback failed after apply error; parent=%s groups=%s",
                    self.parent_image_dir,
                    [group.image_names for group in self.groups],
                )
                raise SeparationFileError(
                    f"Separation failed and rolling back the files also failed: {rollback_error}"
                ) from error
            if isinstance(error, SeparationFileError):
                raise
            raise SeparationFileError(f"Physical file separation failed: {error}") from error

    def rollback(self) -> None:
        errors: list[str] = []
        fs_path(self.parent_image_dir).mkdir(parents=True, exist_ok=True)
        if self.parent_thumbnail_dir:
            fs_path(self.parent_thumbnail_dir).mkdir(parents=True, exist_ok=True)

        for group in reversed(self.groups):
            image_dir = (
                group.final_image_dir
                if fs_path(group.final_image_dir).exists()
                else group.temporary_image_dir
            )
            thumbnail_dir = None
            if group.final_thumbnail_dir and fs_path(group.final_thumbnail_dir).exists():
                thumbnail_dir = group.final_thumbnail_dir
            elif group.temporary_thumbnail_dir and fs_path(group.temporary_thumbnail_dir).exists():
                thumbnail_dir = group.temporary_thumbnail_dir

            for image_name in reversed(group.image_names):
                source = image_dir / image_name
                target = self.parent_image_dir / image_name
                if fs_path(source).is_file():
                    try:
                        if fs_path(target).exists():
                            raise FileExistsError(f"The rollback target file already exists: {target}")
                        shutil.move(str(fs_path(source)), str(fs_path(target)))
                    except Exception as error:
                        errors.append(f"{source} -> {target}: {error}")

                if thumbnail_dir is None or self.parent_thumbnail_dir is None:
                    continue
                thumbnail = thumbnail_dir / image_name
                if not fs_path(thumbnail).is_file():
                    continue
                try:
                    if image_name in self._source_thumbnails:
                        target_thumbnail = self.parent_thumbnail_dir / image_name
                        if fs_path(target_thumbnail).exists():
                            raise FileExistsError(f"The rollback target thumbnail already exists: {target_thumbnail}")
                        shutil.move(str(fs_path(thumbnail)), str(fs_path(target_thumbnail)))
                    else:
                        fs_path(thumbnail).unlink()
                except Exception as error:
                    errors.append(f"Thumbnail {thumbnail}: {error}")

            self._remove_if_empty(image_dir)
            if thumbnail_dir:
                self._remove_if_empty(thumbnail_dir)

        self._applied = False
        if errors:
            raise SeparationFileError("; ".join(errors))

    def cleanup_empty_parent_directories(self) -> None:
        self._remove_if_empty(self.parent_image_dir)
        if self.parent_thumbnail_dir:
            self._remove_if_empty(self.parent_thumbnail_dir)

    @staticmethod
    def _remove_if_empty(path: Path) -> None:
        try:
            fs_path(path).rmdir()
        except FileNotFoundError:
            return
        except OSError:
            logger.warning("QC separation retained non-empty directory: %s", path)
