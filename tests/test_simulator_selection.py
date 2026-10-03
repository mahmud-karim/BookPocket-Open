"""CI must select a real second small device, not silently retest a large phone."""
from test_release_tools import module
import pytest


def inventory(*names):
    return {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
        {"name": name, "udid": str(index), "isAvailable": True} for index, name in enumerate(names)]}}


def test_compact_selection_uses_available_smaller_model_and_preserves_large_default():
    selector = module("select_simulator")
    data = inventory("iPhone 17 Pro Max", "iPhone 17 Pro", "iPhone 16e")
    large = selector.select_device(data, "26")
    assert large["name"] == "iPhone 17 Pro Max"
    compact = selector.select_device(data, "26", compact=True, exclude=large["udid"])
    assert compact["name"] == "iPhone 16e"
    assert compact["udid"] != large["udid"]


def test_selection_ignores_unavailable_wrong_sdk_and_excluded_devices():
    selector = module("select_simulator")
    data = inventory("iPhone SE (3rd generation)", "iPhone 13 mini", "iPhone 16e", "iPhone 17")
    data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-0"][0]["isAvailable"] = False
    data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-18-0"] = [{"name": "iPhone SE (3rd generation)", "udid": "older-runtime", "isAvailable": True}]
    assert selector.select_device(data, 26, compact=True)["name"] == "iPhone 13 mini"
    assert selector.select_device(data, 26, compact=True, exclude="1")["name"] == "iPhone 16e"


@pytest.mark.parametrize("names,excluded", [(["iPhone 17 Pro Max", "iPhone 16 Plus", "iPhone Air"], None), (["iPhone 16e"], "0")])
def test_missing_second_compact_device_is_a_failure_not_large_device_fallback(names, excluded):
    with pytest.raises(ValueError, match="distinct available compact"):
        module("select_simulator").select_device(inventory(*names), 26, compact=True, exclude=excluded)
