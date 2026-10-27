import {spawn} from 'node:child_process';
import {join} from 'node:path';
/** The Mac provider owns its local profile; API/domain code never constructs model commands. */
export function startCodexProcess({home,workspace,binary=process.env.VESPER_CODEX_BIN||'codex'}) {
  return spawn(binary,['app-server','--listen','ws://127.0.0.1:47632','--ws-auth','capability-token','--ws-token-file',join(home,'device-token')],
    {cwd:workspace,env:{...process.env,CODEX_HOME:join(home,'codex')},stdio:['ignore','ignore','pipe']});
}
