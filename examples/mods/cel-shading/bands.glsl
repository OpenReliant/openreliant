// The cel-shading mod's lighting function (cel.luau): each light falls in a few flat bands rather
// than fading smoothly across a surface. parameters.x is how many bands there are.
float lighting(float cosine, vec4 parameters) {
    float bands = max(parameters.x, 1.0);
    // Anything the light reaches takes at least the darkest band, and the brightest band is full.
    return ceil(cosine * bands) / bands;
}
