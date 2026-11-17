//  When the URL contains `?flush` query parameter, reset the `<body>` margin
//      to 0. This is useful when the page is embedded in an `iFrame` (e.g.,
//      Confluence iFrame macro), where the default 8px `<body>` margin reduces
//      the content ViewPort.
export function ResetBodyMargin() {
    if (new URLSearchParams(window.location.search).has('flush'))
        document.body.style.margin = '0';
}
