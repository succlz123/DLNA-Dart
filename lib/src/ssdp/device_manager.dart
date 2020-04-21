import 'dart:async';

import '../dlna_device.dart';
import '../dlna_manager.dart';
import 'description_parser.dart';
import 'local_device_parser.dart';

class DiscoveryDeviceManger {
  static const int FROM_ADD = 1;
  static const int FROM_UPDATE = 2;
  static const int FROM_CACHE_ADD = 3;

  // 150s = 2.5min
  static const int DEVICE_DESCRIPTION_INTERVAL_TIME = 150000;

  // 60s = 1min
  static const int DEVICE_ALIVE_OFFSET_TIME = 60000;

  final int _startSearchTime = DateTime.now().millisecondsSinceEpoch;
  final List<String> _descTasks = [];
  final Map<String, int> _unnecessaryDevices = {};
  final Map<String, DLNADevice> _currentDevices = {};

  final DescriptionParser _descriptionParser = DescriptionParser();
  final LocalDeviceParser _localDeviceParser = LocalDeviceParser();

  Timer _timer;
  bool _enableCache = false;
  bool _disable = true;
  DeviceRefresher _refresher;

  void enableCache() {
    _enableCache = true;
  }

  Future<List<DLNADevice>> getLocalDevices() async {
    return _localDeviceParser.findAndConvert();
  }

  void setRefresh(DeviceRefresher refresher) {
    _refresher = refresher;
    if (_refresher != null) {
      _currentDevices.forEach((key, value) {
        _refresher.onDeviceAdd(value);
      });
    }
  }

  void enable() {
    _disable = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      onAliveCheck();
    });
    if (_enableCache) {
      getLocalDevices().then((devices) {
        if (devices != null) {
          for (var device in devices) {
            onCacheAlive(device);
          }
        }
      }).catchError((error) {});
    }
  }

  void disable() {
    if (_timer != null) {
      _timer.cancel();
      _timer = null;
    }
    _disable = true;
  }

  void onRelease() {
    disable();
    _refresher = null;
    _descriptionParser.stop();
    _descTasks.clear();
    _unnecessaryDevices.clear();
    _currentDevices.clear();
  }

  void onCacheAlive(DLNADevice device) async {
    if (_disable) {
      return;
    }
    var hasTask = _descTasks.contains(device.uuid);
    if (hasTask) {
      return;
    }
    _descTasks.add(device.uuid);
    await getDescription(device, 0, FROM_CACHE_ADD);
  }

  Future<void> onAlive(String usn, String location, String cache) async {
    if (_disable) {
      return;
    }
    var split = usn.split('::').where((element) => element.isNotEmpty);
    if (split.isEmpty) {
      return;
    }
    var uuid = split.first;
    var cacheTime = 3600;
    try {
      // max-age=
      cacheTime = int.parse(cache.substring(8));
      // ignore: empty_catches
    } catch (ignore) {}
    DLNADevice tmpDevice = _currentDevices[uuid];
    if (tmpDevice == null) {
      int count = _unnecessaryDevices[location] ??= 0;
      if (count > 3) {
        return;
      }
      var hasTask = _descTasks.contains(uuid);
      if (hasTask) {
        return;
      }
      var device = DLNADevice();
      device
        ..usn = usn
        ..uuid = uuid
        ..location = location
        ..setCacheControl = cacheTime;
      _descTasks.add(device.uuid);
      await getDescription(device, count, FROM_ADD);
    } else {
      var hasTask = _descTasks.contains(uuid);
      if (hasTask) {
        return;
      }
      var isLocationChang = (location != tmpDevice.location);
      var updateTime = tmpDevice.lastDescriptionTime;
      var diff = DateTime.now().millisecondsSinceEpoch - updateTime;
      if (diff > 0 || isLocationChang) {
        tmpDevice
          ..usn = usn
          ..uuid = uuid
          ..location = location
          ..setCacheControl = cacheTime;
        _descTasks.add(uuid);
        await getDescription(tmpDevice, 0, FROM_UPDATE);
      }
    }
  }

  void onByeBye(String usn) {
    if (_disable) {
      return;
    }
    var split = usn.split('::').where((element) => element.isNotEmpty);
    if (split == null || split.isEmpty) {
      return;
    }
    onRemove(split.first);
  }

  void onAliveCheck() {
    if (_disable) {
      return;
    }
    _currentDevices.removeWhere((key, value) {
      var currentTime = DateTime.now().millisecondsSinceEpoch;
      var needRemove = currentTime > value.expirationTime;
      if (needRemove) {
        needRemove = (currentTime - value.lastDescriptionTime) >
            DEVICE_DESCRIPTION_INTERVAL_TIME + DEVICE_ALIVE_OFFSET_TIME;
      }
      if (needRemove) {
        onAliveCheckRemove(value);
      }
      return needRemove;
    });
  }

  Future<void> getDescription(DLNADevice device, int tryCount, int type) async {
    try {
      var descriptionTaskStartTime = DateTime.now().millisecondsSinceEpoch;
      var desc = await _descriptionParser.getDescription(device);
      if (desc.avTransportControlURL == null ||
          desc.avTransportControlURL.isEmpty) {
        tryCount++;
        onUnnecessary(device, tryCount);
        return;
      }
      device.description = desc;
      device.lastDescriptionTime = DateTime.now().millisecondsSinceEpoch +
          DEVICE_DESCRIPTION_INTERVAL_TIME;
      device.descriptionTaskSpendingTime =
          DateTime.now().millisecondsSinceEpoch - descriptionTaskStartTime;
      switch (type) {
        case FROM_ADD:
          {
            onAdd(device);
          }
          break;
        case FROM_UPDATE:
          {
            onUpdate(device);
          }
          break;
        case FROM_CACHE_ADD:
          {
            onCacheAdd(device);
          }
          break;
        default:
          {}
          break;
      }
    } catch (e) {
      onSearchError(device.toString() + '\n' + e.toString());
    }
  }

  void onSearchError(String message) {
    _refresher?.onSearchError(message);
  }

  void onUnnecessary(DLNADevice device, int count) {
    _unnecessaryDevices[device.location] = count;
    _descTasks.remove(device.uuid);
  }

  void onAdd(DLNADevice device) {
    device.discoveryFromStartSpendingTime =
        DateTime.now().millisecondsSinceEpoch - _startSearchTime;
    device.isFromCache = false;
    _currentDevices[device.uuid] = device;
    if (_enableCache) {
      _localDeviceParser.saveDevices(_currentDevices);
    }
    _descTasks.remove(device.uuid);
    _refresher?.onDeviceAdd(device);
  }

  void onCacheAdd(DLNADevice device) {
    device.discoveryFromStartSpendingTime =
        DateTime.now().millisecondsSinceEpoch - _startSearchTime;
    device.isFromCache = true;
    _currentDevices[device.uuid] = device;
    if (_enableCache) {
      _localDeviceParser.saveDevices(_currentDevices);
    }
    _descTasks.remove(device.uuid);
    _refresher?.onDeviceAdd(device);
  }

  void onUpdate(DLNADevice device) {
    _currentDevices[device.uuid] = device;
    if (_enableCache) {
      _localDeviceParser.saveDevices(_currentDevices);
    }
    _descTasks.remove(device.uuid);
    _refresher?.onDeviceUpdate(device);
  }

  void onAliveCheckRemove(DLNADevice device) {
    if (_enableCache) {
      _localDeviceParser.saveDevices(_currentDevices);
    }
    _refresher?.onDeviceRemove(device);
  }

  void onRemove(String uuid) {
    DLNADevice device = _currentDevices.remove(uuid);
    if (device != null) {
      if (_enableCache) {
        _localDeviceParser.saveDevices(_currentDevices);
      }
      _refresher?.onDeviceRemove(device);
    }
  }
}
