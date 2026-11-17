// Diagnostic module: one home-page list with a single film. If this appears in Rex's
// module list and Torrentio does not, Rex is hiding resource-only modules from the list.
WidgetMetadata = {
  id: "community.hellotest",
  title: "Hello Test",
  version: "1.0.0",
  requiredVersion: "0.0.1",
  description: "Diagnostic module with one list",
  author: "Community",
  modules: [
    {
      id: "helloList",
      title: "Hello List",
      functionName: "helloList",
      cacheDuration: 60,
      params: [],
    },
  ],
};

async function helloList(params) {
  return [
    { id: "278", type: "tmdb", mediaType: "movie", title: "The Shawshank Redemption" },
  ];
}
