#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ACOPS1206
# Source: https://github.com/ACOPS1206/MusicSync

"""Validate products, preserve bundle modes/symlinks, produce unsigned IPA + ad-hoc Mac app."""
import pathlib, plistlib, shutil, subprocess, sys, zipfile

def run(*args): subprocess.run(args,check=True)
def verify(app, platform):
    plist=app/('Contents/Info.plist' if platform=='macOS' else 'Info.plist')
    info=plistlib.loads(plist.read_bytes())
    executable=app/('Contents/MacOS' if platform=='macOS' else '')/info['CFBundleExecutable']
    if not executable.is_file(): raise RuntimeError('Missing executable: '+str(executable))
    run('file',str(executable))
    minimum=info.get('LSMinimumSystemVersion') if platform=='macOS' else info.get('MinimumOSVersion')
    if minimum != '26.0': raise RuntimeError('Unexpected minimum OS: '+str(minimum))
    resources = app/'Contents/Resources' if platform=='macOS' else app
    for language in ['en','ko']:
        for filename in ['Localizable.strings','InfoPlist.strings']:
            if not (resources/(language+'.lproj')/filename).is_file():
                raise RuntimeError('Missing localization: '+language+'/'+filename)
    for filename in ['LICENSE','NOTICE']:
        if not (resources/filename).is_file(): raise RuntimeError('Missing license/attribution: '+filename)
    if platform == 'iOS':
        if not info.get('NSSupportsLiveActivities'): raise RuntimeError('Live Activities support is missing')
        extension = app/'PlugIns/MusicSyncWidgets.appex'
        widget_info = plistlib.loads((extension/'Info.plist').read_bytes())
        if widget_info.get('NSExtension',{}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension': raise RuntimeError('Invalid WidgetKit extension')
        if not (extension/widget_info['CFBundleExecutable']).is_file(): raise RuntimeError('Missing widget executable')
        if not widget_info['CFBundleIdentifier'].startswith(info['CFBundleIdentifier'] + '.'): raise RuntimeError('Widget bundle ID must extend app ID')
        if widget_info['CFBundleVersion'] != info['CFBundleVersion']: raise RuntimeError('Widget build version mismatch')
    return info

def main():
    ios,mac,out=map(lambda x:pathlib.Path(x).resolve(),sys.argv[1:])
    verify(ios,'iOS'); verify(mac,'macOS'); out.mkdir(parents=True,exist_ok=True)
    stage=out/'staging'
    if stage.exists(): shutil.rmtree(stage)
    (stage/'Payload').mkdir(parents=True)
    shutil.copytree(ios,stage/'Payload/MusicSync.app',symlinks=True)
    run('ditto','-c','-k','--keepParent',str(stage/'Payload'),str(out/'MusicSync-iOS.ipa'))
    run('ditto','-c','-k','--keepParent',str(ios),str(out/'MusicSync-iOS.app.zip'))
    mac_copy=stage/'MusicSync-macOS.app'; shutil.copytree(mac,mac_copy,symlinks=True)
    # Apple Silicon requires a valid signature; ad-hoc signing uses no developer certificate.
    run('codesign','--force','--deep','--sign','-',str(mac_copy))
    run('codesign','--verify','--deep','--strict',str(mac_copy))
    run('ditto','-c','-k','--keepParent',str(mac_copy),str(out/'MusicSync-macOS.zip'))
    with zipfile.ZipFile(out/'MusicSync-iOS.ipa') as archive:
        names=archive.namelist()
        if 'Payload/MusicSync.app/Info.plist' not in names: raise RuntimeError('Invalid IPA layout')
        if 'Payload/MusicSync.app/PlugIns/MusicSyncWidgets.appex/Info.plist' not in names: raise RuntimeError('IPA missing Live Activity extension')
        if any('embedded.mobileprovision' in name for name in names): raise RuntimeError('IPA must be unsigned')
    shutil.rmtree(stage)
    print('Verified IPA layout, OS targets, executables and macOS ad-hoc signature.')
if __name__=='__main__': main()
