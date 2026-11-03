#!/usr/bin/env bash
set -euo pipefail
umask 077
if [ "$(id -u)" -ne 0 ]; then echo 'Run as root'; exit 1; fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work="/root/streamalert-migration-$stamp"
mkdir -m 700 "$work"
for name in streamalert-access streamalert-https; do
  docker inspect "$name" > "$work/$name.inspect.json"
done
python3 - "$work" <<'PY'
import json, pathlib, sys
work=pathlib.Path(sys.argv[1]); paths={'/opt/streamalert','/var/lib/streamalert','/etc/streamalert'}
for name in ('streamalert-access','streamalert-https'):
    info=json.loads((work/(name+'.inspect.json')).read_text())[0]
    for mount in info.get('Mounts',[]):
        source=mount.get('Source')
        if source: paths.add(source)
    # Preserve explicitly configured signing key paths on the host when available.
    for item in info.get('Config',{}).get('Env',[]):
        if item.startswith('SAS_UPDATE_PRIVATE_KEY_FILE='):
            p=item.split('=',1)[1]
            if pathlib.Path(p).is_file(): paths.add(p)
for p in paths:
    if not pathlib.Path(p).exists(): raise SystemExit('Missing backup path: '+p)
(work/'paths.txt').write_text('\n'.join(sorted(p.lstrip('/') for p in paths))+'\n')
PY
running=$(docker inspect -f '{{.State.Running}}' streamalert-access)
restart_service(){ if [ "$running" = true ]; then docker start streamalert-access >/dev/null; fi; }
trap restart_service EXIT
if [ "$running" = true ]; then docker stop -t 30 streamalert-access >/dev/null; fi
archive="$work.tar.gz"
tar -czpf "$archive" -C / -T "$work/paths.txt" -C / "${work#/}"
chmod 600 "$archive"
sha256sum "$archive" > "$archive.sha256"
restart_service
trap - EXIT
printf 'BACKUP_READY: %s\n' "$archive"
cat "$archive.sha256"
