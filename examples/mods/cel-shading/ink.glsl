// The cel-shading mod's surface function (cel.luau): a dark line round the outlines of the ships,
// and flatter colours.
// parameters.x: how wide the line is, in pixels.
// parameters.y: how many levels each colour channel keeps, or 0 to keep them all.
void surface(inout Surface s, vec4 parameters, float time) {
    // How far the surface is from turning away from the eye, and how fast that changes across the
    // screen: the line is where it turns away within `parameters.x` pixels, which is the outline of
    // a curved hull, and not on a flat panel seen from the side. Worked out before anything returns,
    // as a derivative needs every pixel around it.
    float facing = dot(s.normal, s.toEye);
    float change = fwidth(facing);
    // Sprites and effects have no normal, and get neither.
    if (dot(s.normal, s.normal) < 0.5) return;
    if (parameters.y > 0.0) s.colour = floor(s.colour * parameters.y + 0.5) / parameters.y;
    if (facing < parameters.x * change) {
        s.colour = vec3(0.0);
        s.glow = vec3(0.0);
    }
}
