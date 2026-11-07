// Export the film's subtitle cues (window.SUBS) to out/subs.json for srt.py. Run from anywhere: node tools/subs.mjs <film folder>  (LIB must be set)
import fs from 'node:fs'; import path from 'node:path'; import { pathToFileURL } from 'node:url';
const HERE = path.resolve(process.argv[2] || '.'), LIB = process.env.LIB;
const { openDemo } = await import(pathToFileURL(path.join(LIB, 'core/render/page.mjs')).href);
const { browser, page } = await openDemo(HERE);
const subs = await page.evaluate(() => window.SUBS);
fs.writeFileSync(path.join(HERE, 'out', 'subs.json'), JSON.stringify(subs.sort((a, b) => a.t0 - b.t0), null, 1));
console.log('subs', subs.length); await browser.close(); process.exit(0);
