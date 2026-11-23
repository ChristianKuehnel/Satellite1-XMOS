import pytest
import subprocess
import argparse

from unittest.mock import patch, MagicMock
from versioning import GitInfo, assert_clean_workspace, track_dev_build
import versioning


# ✅ Mock subprocess output for Git commands
@patch("subprocess.run")
def test_git_info(mock_subproc):
    """Test GitInfo.from_ws() with mocked Git responses."""

    # Create a mock return object with `.stdout.strip()`
    def mock_git_command(args, cwd, capture_output, text, check):
        mock = MagicMock()
        
        # Simulated outputs for each Git command
        if args == ["git", "rev-parse", "--abbrev-ref", "HEAD"]:
            mock.stdout = "main\n"
        elif args == ["git", "rev-parse", "--short", "HEAD"]:
            mock.stdout = "abc123\n"
        elif args == ["git", "status", "--porcelain"]:
            mock.stdout = ""  # No changed files
        elif args[:2] == ["git", "describe"]:
            mock.stdout = "v1.2.3\n"
        elif args == ["git", "diff"]:
            mock.stdout = "patch content"
        return mock

    # Set side_effect for mock_subproc
    mock_subproc.side_effect = mock_git_command

    # Call the function being tested
    git_info = GitInfo.from_ws()

    # ✅ Assertions
    assert git_info.branch == "main"
    assert git_info.commit == "abc123"
    assert git_info.last_tag == "v1.2.3"
    assert git_info.patch_str == "patch content"
    assert git_info.dirty is False

# ✅ Mock case where no Git tags exist
@patch("subprocess.run")
def test_git_info_no_tags(mock_subproc):
    """Test GitInfo when no Git tags exist."""

    def mock_git_command(args, cwd, capture_output, text, check):
        mock = MagicMock()
        if args == ["git", "rev-parse", "--abbrev-ref", "HEAD"]:
            mock.stdout = "main\n"
        elif args == ["git", "rev-parse", "--short", "HEAD"]:
            mock.stdout = "abc123\n"
        elif args == ["git", "status", "--porcelain"]:
            mock.stdout = " "
        elif args[:2] == ["git", "describe"]:
            raise subprocess.CalledProcessError(1, "git describe")  # Simulate no tags
        elif args == ["git", "diff"]:
            mock.stdout = "patch content"
        return mock

    mock_subproc.side_effect = mock_git_command

    git_info = GitInfo.from_ws()

    # ✅ Expect branch and commit, but last_tag should be None
    assert git_info.branch == "main"
    assert git_info.commit == "abc123"
    assert git_info.last_tag is None


def test_git_info_ignores_dev_release_tags(tmp_path):
    def git(*args):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True)

    git("init", "--quiet")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    git("commit", "--allow-empty", "-m", "Release")
    git("tag", "v1.2.3-beta.1")
    git("commit", "--allow-empty", "-m", "Dev build")
    git("tag", "dev-20261116-7b6f332")

    assert GitInfo.from_ws(tmp_path).last_tag == "v1.2.3-beta.1"


@patch("versioning.GitInfo.from_ws")
def test_assert_clean_workspace_rejects_dirty_build(mock_from_ws):
    git_info = MagicMock()
    git_info.dirty = True
    mock_from_ws.return_value = git_info

    with pytest.raises(SystemExit):
        assert_clean_workspace(argparse.Namespace(allow_dirty=False))


@patch("versioning.GitInfo.from_ws")
def test_assert_clean_workspace_allows_dirty_build_with_flag(mock_from_ws):
    git_info = MagicMock()
    git_info.dirty = True
    mock_from_ws.return_value = git_info

    assert_clean_workspace(argparse.Namespace(allow_dirty=True))


@patch("versioning.GitInfo.from_ws")
def test_dirty_dev_build_is_not_stored(mock_from_ws, tmp_path):
    mock_from_ws.return_value = GitInfo(
        branch="feature",
        commit="abc123",
        last_tag="v1.2.3",
        status_str="M file.c",
    )

    tracked_build = track_dev_build(
        argparse.Namespace(
            variant="satellite1_firmware_fixed_delay",
            build_dir=tmp_path,
        )
    )

    assert str(tracked_build.version) == "v1.2.3-dev"
    assert tracked_build.track_path is None
    assert not (tmp_path / "dev_tracking").exists()


@patch("versioning.GitInfo.from_ws")
def test_clean_dev_builds_increment_even_for_same_commit(
    mock_from_ws,
    tmp_path,
    monkeypatch,
):
    monkeypatch.setattr(versioning, "DEFAULT_DEV_TRACK_PATH", tmp_path)
    mock_from_ws.return_value = GitInfo(
        branch="feature",
        commit="abc123",
        last_tag="v1.2.3",
        status_str="",
    )
    args = argparse.Namespace(
        variant="satellite1_firmware_fixed_delay",
        build_dir=tmp_path,
    )

    first_build = track_dev_build(args)
    second_build = track_dev_build(args)

    assert str(first_build.version) == "v1.2.3-dev.100"
    assert str(second_build.version) == "v1.2.3-dev.101"
    assert first_build.track_path == tmp_path / "v1.2.3-dev.100"
    assert second_build.track_path == tmp_path / "v1.2.3-dev.101"
