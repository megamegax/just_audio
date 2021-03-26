//
//  Generated file. Do not edit.
//

#include "generated_plugin_registrant.h"

#include <dart_vlc/dart_vlc_plugin.h>
#include <just_audio_vlc/just_audio_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) dart_vlc_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "DartVlcPlugin");
  dart_vlc_plugin_register_with_registrar(dart_vlc_registrar);
  g_autoptr(FlPluginRegistrar) just_audio_vlc_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "JustAudioPlugin");
  just_audio_plugin_register_with_registrar(just_audio_vlc_registrar);
}
