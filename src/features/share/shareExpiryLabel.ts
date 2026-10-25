import { formatInstant } from '../../utils/datetime';
import { zoneOffsetMinutesAt } from '../../utils/timezone';
import { formatUtcOffset } from '../event/formInstant';

/**
 * The expiry line of a share link in the list: the date and time in the
 * viewer's zone, then the UTC offset IN FORCE AT THAT INSTANT (E4, P8-c3.1).
 *
 *   2026/11/1 1:30:00 UTC−04:00   the 1st 01:30 in New York
 *   2026/11/1 1:30:00 UTC−05:00   the 2nd
 *
 * Without the offset those two read the same and the owner cannot tell which
 * hour their link dies in. The offset is read for the stored instant, never the
 * device's current offset, so a link that expires after a switch shows the
 * offset of after the switch. 30- and 45-minute offsets print as they are
 * (UTC+05:30, UTC+05:45). Display only: the decision (shareLinkStatus) and the
 * stored value never see this.
 *
 * `timeZone` is the zone formatInstant renders in (getUserTimeZone, the
 * browser's); passing the same zone keeps the clock and the offset about the
 * same place. The date part is formatInstant's, unchanged, so the Japanese and
 * English lines keep their existing form and only gain the offset.
 */
export function shareExpiryLabel(iso: string, locale: string, timeZone: string): string {
  return `${formatInstant(iso, locale)} ${formatUtcOffset(zoneOffsetMinutesAt(Date.parse(iso), timeZone))}`;
}
