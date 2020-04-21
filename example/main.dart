import 'package:dlna/dlna.dart';

Future<void> main() async {
  var dlnaService = DLNAManager();
  dlnaService.setRefresher(DeviceRefresher(onDeviceAdd: (dlnaDevice) {
    print('add ' + dlnaDevice.toString());
  }, onDeviceRemove: (dlnaDevice) {
    print('remove ' + dlnaDevice.toString());
  }, onDeviceUpdate: (dlnaDevice) {
    print('update ' + dlnaDevice.toString());
  }, onSearchError: (error) {
    print(error);
  }, onPlayProgress: (positionInfo) {
    print('current play progress ' + positionInfo.relTime);
  }));
  dlnaService.startSearch();
}
