/* The webfonts' stylesheet is fetched as `media="print"`, which blocks nothing, and is
   switched on here once it has arrived, so a page with no route to the fonts' host
   renders in its fallback fonts rather than waiting for them. A file rather than the
   `onload` attribute it replaces, because this origin runs no inline script
   (Decision 803). Served at /static/ for the front page and the console alike. */
(function () {
  "use strict";

  var links = document.querySelectorAll("link[data-webfonts]");

  Array.prototype.forEach.call(links, function (link) {
    // Already arrived before this ran: a stylesheet that has loaded has a sheet.
    if (link.sheet) {
      link.media = "all";
      return;
    }

    link.addEventListener("load", function () {
      link.media = "all";
    });
  });
})();
