/*
 * ISO disc image auto-detection.
 *
 * Opens URLs (http/https/webdav) and local files whose name ends in .iso/.img
 * as optical discs: the source is first probed as a Blu-ray (libbluray) and,
 * if that fails, as a DVD-Video (libdvdnav). Both libraries read the image
 * through mpv's stream layer, so remote images work over HTTP range requests
 * just like local files.
 *
 * If the source is neither kind of disc, STREAM_UNSUPPORTED is returned and
 * regular playback (e.g. libarchive) takes over.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or modify it under the
 * terms of the GNU Lesser General Public License as published by the Free
 * Software Foundation; either version 2.1 of the License, or (at your option)
 * any later version.
 *
 * mpv is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for
 * more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with mpv. If not, see <http://www.gnu.org/licenses/>.
 */

#include "config.h"

#if HAVE_LIBBLURAY || HAVE_DVDNAV

#include "mpv_talloc.h"

#include "common/common.h"
#include "common/msg.h"
#include "misc/bstr.h"
#include "stream.h"

#if HAVE_LIBBLURAY
extern const stream_info_t stream_info_bluray;
#endif
#if HAVE_DVDNAV
extern const stream_info_t stream_info_dvdnav;
#endif

static bool has_iso_extension(bstr url)
{
    // Ignore everything after a query string or fragment.
    for (int n = 0; n < url.len; n++) {
        if (url.start[n] == '?' || url.start[n] == '#') {
            url.len = n;
            break;
        }
    }

    static const char *const exts[] = {".iso", ".img", NULL};
    for (int n = 0; exts[n]; n++) {
        if (bstr_case_endswith(url, bstr0(exts[n])))
            return true;
    }
    return false;
}

static int iso_open(stream_t *s)
{
    if (!has_iso_extension(bstr0(s->url)))
        return STREAM_UNSUPPORTED;

    MP_VERBOSE(s, "ISO image detected, trying to open it as a disc.\n");

    int r;
#if HAVE_LIBBLURAY
    r = mp_bluray_open_disc_url(s, s->url);
    if (r != STREAM_UNSUPPORTED) {
        // Adopt the backend's identity, so that demuxer and player code that
        // dispatches on stream->info->name (DVD sub streams, angles, ...)
        // sees a real disc backend.
        if (r == STREAM_OK)
            s->info = &stream_info_bluray;
        return r;
    }
#endif
#if HAVE_DVDNAV
    r = mp_dvdnav_open_disc_url(s, s->url);
    if (r != STREAM_UNSUPPORTED) {
        if (r == STREAM_OK)
            s->info = &stream_info_dvdnav;
        return r;
    }
#endif

    // Not a Blu-ray or DVD-Video image; let other stream layers handle it.
    return STREAM_UNSUPPORTED;
}

const stream_info_t stream_info_iso = {
    .name = "iso",
    .open = iso_open,
    .protocols = (const char*const[]){ "file", "", "http", "https",
                                       "webdav", "webdavs", "dav", "davs",
                                       NULL },
    .stream_origin = STREAM_ORIGIN_UNSAFE,
};

#endif // HAVE_LIBBLURAY || HAVE_DVDNAV
