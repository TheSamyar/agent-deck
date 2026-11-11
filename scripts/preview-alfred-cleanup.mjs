import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Read-only: show the exact tracked dependency files left by the Alfred split.
// Index removal requires a separate, explicitly approved command.
const root = fileURLToPath(new URL('../', import.meta.url));
const files = execFileSync('git', ['ls-files', '-z', '--', 'alfred-server/node_modules/'], {
  cwd: root,
  encoding: 'utf8',
}).split('\0').filter(Boolean);
console.log(`Tracked Alfred dependency files: ${files.length}`);
for (const file of files) console.log(file);
if (files.length) {
  console.log('\nAfter approval, untrack these files while preserving them on disk:');
  console.log('git rm -r --cached -- alfred-server/node_modules');
  console.log('No files or Git index entries were changed by this preview.');
}
