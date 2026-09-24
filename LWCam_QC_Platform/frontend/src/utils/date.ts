// One formatter for every timestamp the console displays, so the format is a
// single decision instead of one per call site. The backend sends ISO
// strings (UTC or with an offset); `new Date` parses either, and the getters
// below read it back in the VIEWER's local time zone.
//
// An absent value renders as `placeholder`, not as an empty cell. A blank
// space in a table cannot be told apart from a value that failed to load,
// and "this folder has never been exported" is a real answer the operator
// needs - it just isn't a date. Only a value that is present and genuinely
// unparseable falls through to the same dash, because there is nothing
// truthful to print for it either.
export function formatTimestamp(value?: string | null, placeholder = '—'): string {
  if (!value) return placeholder
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return placeholder
  const pad = (n: number) => String(n).padStart(2, '0')
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  )
}
