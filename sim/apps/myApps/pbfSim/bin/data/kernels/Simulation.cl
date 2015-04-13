/*******************************************************************************
 * UpdatePositions.cl
 * - The OpenCL kernel responsible for apply external forces, like gravity
 *   for instance to each particle in the simulation, and subsequenly updating
 *   the predicted position of each particle using a simple explicit Euler
 *   step
 *
 * CIS563: Physically Based Animation final project
 * Created by Michael Woods & Michael O'Meara
 ******************************************************************************/

/*******************************************************************************
 * Constants
 ******************************************************************************/

/**
 * Acceleration due to gravity: 9.8 m/s
 */
#define G 9.8f

/*******************************************************************************
 * Types
 ******************************************************************************/

// A particle type:

typedef struct {
    
    float4 pos;    // 4 words
    
    float4 vel;    // 4 words
    
    float  mass;   // 1 word

    float  radius; // 1 word

    /**
     * VERY IMPORTANT: This is needed so that the struct's size is aligned
     * for x86 memory access along 4/word 16 byte intervals.
     *
     * If the size is not aligned, results WILL be screwed up!!!
     * Don't be like me and waste hours trying to debug this issue. The
     * OpenCL compiler WILL NOT pad your struct to so that boundary aligned
     * like g++/clang will in host (C++) land!!!.
     *
     * See http://en.wikipedia.org/wiki/Data_structure_alignment
     */
    float  __dummy[2]; // 2 words

} Particle; // total = 12 words = 64 bytes

// A type to represent the position of a given particle in the spatial
// grid the simulated world is divided into

typedef struct {

    int particleIndex; // Index of particle in particle buffer (1 word)

    int cellI;         // Corresponding grid index in the x-axis (1 word)
    
    int cellJ;         // Corresponding grid index in the y-axis (1 word)
    
    int cellK;         // Corresponding grid index in the z-axis (1 word)

} ParticlePosition;

// A type that encodes the start and length of a grid cell in sortedParticleToCell

typedef struct {
    
    int  start; // Start of the grid cell in sortedParticleToCell
    
    int length;
    
    int __dummy[2]; // Padding
    
} GridCellOffset;

// Smoothing kernel enum:

enum SmoothingKernel
{
     POLY_6
    ,SPIKY
};

/*******************************************************************************
 * Helper functions
 ******************************************************************************/

/**
 * A helper function that scales a value x in the range [a0,a1] to a new
 * range [b0,b1]
 */
float rescale(float x, float a0, float a1, float b0, float b1)
{
    return ((x - a0) / (a1 - a0)) * (b1 - b0) + b0;
}

/**
 * A function that converts a 3D subscript (i,j,k) into a linear index
 *
 * @param [in] int i x component of subscript
 * @param [in] int j y component of subscript
 * @param [in] int k z component of subscript
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int sub2ind(int i, int j, int k, int w, int h)
{
    return i + (j * w) + k * (w * h);
}

/**
 * A function that converts a linear index x into a 3D subscript (i,j,k)
 *
 * @param [in] int x The linear index x
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int3 ind2sub(int x, int w, int h)
{
    return (int3)(x % w, (x / w) % h, x / (w * h));
}

/**
 * Given the subscript (i,j,k) as an int3 of a cell to search the vicinity of,
 * this function will return a count of valid neighboring cells (including
 * itself) in the range [1,27], e.g. between 1 and 27 neighboring cells are
 * valid and need to be searched for neighbors. The indices from 
 * [0 .. neighborCount-1] will be populated with the indices of neighboring 
 * cells in gridCellOffsets, such that for each nerighboring grid cell
 * (i', j', k'), 0 <= i' < cellX, 0 <= j' < cellY, 0 <= k' < cellZ, and the
 * corresponding entry for cell (i',j',k') in gridCellOffsets has a cell 
 * start index != -1.
 *
 * @param [in]  sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX
 * @param [in]  int cellsY
 * @param [in]  int cellsZ
 * @param [in]  int3 cellSubscript
 * @param [out] int* neighbors
 */
int getNeighborsBySubscript(const global ParticlePosition* sortedParticleToCell
                           ,const global GridCellOffset* gridCellOffsets
                           ,int cellsX
                           ,int cellsY
                           ,int cellsZ
                           ,int3 cellSubscript
                           ,int* neighbors)
{
    int i = cellSubscript.x;
    int j = cellSubscript.y;
    int k = cellSubscript.z;
    
    // Count of valid neighbors:

    int neighborCount = 0;

    // We need to search the following potential 27 cells about (i,j,k):
    // (i + [-1,0,1], j + [-1,0,1], k + [-1,0,1]):

    int offsets[3] = { -1, 0, 1};
    int I = -1;
    int J = -1;
    int K = -1;
    
    // -1 indicates an invalid/non-existent neighbor:

    for (int i = 0; i < 27; i++) {
        neighbors[i] = -1;
    }

    for (int u = 0; u < 3; u++) {

        I = i + offsets[u]; // I = i-1, i, i+1

        for (int v = 0; v < 3; v++) {
        
            J = j + offsets[v]; // J = j-1, j, j+1

            for (int w = 0; w < 3; w++) {
            
                K = k + offsets[w]; // K = k-1, k, k+1
                
                if (   (I >= 0 && I < cellsX)
                    && (J >= 0 && J < cellsY)
                    && (K >= 0 && K < cellsZ))
                {
                    int key = sub2ind(cellSubscript.x, cellSubscript.y, cellSubscript.z, cellsX, cellsY);

                    // The specified grid cell offset has a valid starting
                    // index, so we can return it as a valid neighbor:
                    if (gridCellOffsets[key].start != -1) {
                        neighbors[neighborCount++] = key;
                    }
                }
            }
        }
    }
    
    return neighborCount;
}

// Smoothing kernels:

float poly6(float r, float h)
{
    // (315 / (64 * PI * h^9)) * (h^2 - |r|^2)^3
    float h9 = (h * h * h * h * h * h * h * h * h);
    float A  = 1.566681471061 * h9;
    float B  = (h * h) - (r * r);
    return A * (B * B * B);
}

float spiky(float r, float h)
{
    // (45 / (PI * h^6)) * (h - |r|)^2 * (r / |r|)
    float h6   = (h * h * h * h * h * h);
    float A    = 14.323944878271 * h6;
    float rAbs = fabs(r);
    float B    = (h - rAbs);
    return A * (B * B) * (r / rAbs);
}

/*******************************************************************************
 * Kernels
 ******************************************************************************/

/**
 * For all particles p_i in particles, this kernel applies external forces to the
 * velocity of p_i
 *
 * Currently, only applies gravity to the y component of the velocity.
 * Additional forces may be added later like wind and other forms of
 * turbulence, etc.
 *
 *   v_i = v_i + dt + f_external(x_i)
 */
kernel void applyExternalForces(global Particle* particles, float dt)
{
    int i = get_global_id(0);
    
    // Apply the force of gravity along the y-axis:
    particles[i].vel.y += (dt * -G);
}

/**
 * For all particles p_i in particles, this kernel updates the predicted 
 * position of p_i using an explicit Euler step like so:
 *
 * x_i = x_i + (dt * v_i), where x_i is the position of p_i and v_i is
 * the velocity of p_i
 */
kernel void predictPosition(global Particle* particles, float dt)
{
    int i = get_global_id(0);

    // Explicit Euler step:
    particles[i].pos += (dt * particles[i].vel);
}

/**
 * For all particles p_i in particles, this kernel discretizes each p_i's
 * position into a grid of cells with dimensions specified by cellsPerAxis.
 *
 * @param [in] Particle* particles The particles to assign to cells
 * @param [out] int2* particleToCell Each entry contains a int2 pair
 * (i,j), where i is the particle in the i-th entry of particles, and j is
 * the linear index of the corresponding linear bin (j_x, j_y, j_z), where
 * 0 <= j_x < cellsPerAxis.x, 0 <= j_y < cellsPerAxis.y,
 * and 0 <= j_z < cellsPerAxis.z
 * @param [out] int* cellHistogram A histogram of counts of particles per cell
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] float3 minExtent The minimum extent of the simulation's
 *             bounding box in world space
 * @param [in] float3 maxExtent The maximum extent of the simulation's
 *             bounding box in world space
 */
kernel void discretizeParticlePositions(global Particle* particles
                                       ,global ParticlePosition* particleToCell
                                       ,global int* cellHistogram
                                       ,int cellsX
                                       ,int cellsY
                                       ,int cellsZ
                                       ,float3 minExtent
                                       ,float3 maxExtent)
{
    int i = get_global_id(0);
    global Particle *p = &particles[i];
    
    // Now we have the discretized cell at (i, j, k):
    int cellI = (int)(rescale(p->pos.x, minExtent.x, maxExtent.x, 0.0, (float)(cellsX - 1)));
    int cellJ = (int)(rescale(p->pos.y, minExtent.y, maxExtent.y, 0.0, (float)(cellsY - 1)));
    int cellK = (int)(rescale(p->pos.z, minExtent.z, maxExtent.z, 0.0, (float)(cellsZ - 1)));

    particleToCell[i].particleIndex = i;
    
    // Set the (i,j,k) index of the cell:
    particleToCell[i].cellI = cellI;
    particleToCell[i].cellJ = cellJ;
    particleToCell[i].cellK = cellK;
    
    // Compute the linear index for the histogram counter
    int key = sub2ind(cellI, cellJ, cellK, cellsX, cellsY);

    /*
    printf("[%d] @ (%f, %f, %f) => (%d/%d, %d/%d, %d/%d) => %d\n",
           i,
           p->pos.x, p->pos.y, p->pos.z,
           cellI, cellsX, cellJ, cellsY, cellK, cellsZ,
           key);
    */

    // This is needed; "cellHistogram[z] += 1" won't work here as multiple
    // threads are modifying cellHistogram simultaneously:
    atomic_add(&cellHistogram[key], 1);
}

/**
 * NOTE: This kernel is meant to be run with 1 thread. This is necessary
 * since we have to perform a sort and perform some other actions which are
 * inherently sequential in nature
 *
 * This kernel basically performs a counting sort 
 * (http://en.wikipedia.org/wiki/Counting_sort) on the particles, sorting
 * them by the grid cell they were each assigned to. Rather than sorting by
 * a 3 dimensional subscript (i,j,k), we linearize the subscript, and sort by
 * that
 *
 * @see discretizeParticlePositions
 *
 * @param [in] particleToCell
 * @param [in/out] cellHistogram
 * @param [out] sortedParticleToCell
 * @param [out] gridCellOffsets An array of size [0 .. numCells-1], where
 *              each index i contains the start and length of the i-th
 *              cell in the grid as it occurs in sortedParticleToCell
 * @param [in] numParticles The total number of particles in the simulation
 * @param [in] numCells The total number of cells in the spatial grid
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 */
kernel void sortParticlesByCell(global ParticlePosition* particleToCell
                               ,global int* cellHistogram
                               ,global ParticlePosition* sortedParticleToCell
                               ,global GridCellOffset* gridCellOffsets
                               ,int numParticles
                               ,int numCells
                               ,int cellsX
                               ,int cellsY
                               ,int cellsZ)
{
    // First step of counting sort is done already, since we calculated
    //the histogram (cellHistogram) in the discretizeParticlePositions kernel:
    
    int prefixSum = 0;
    int totalSum  = 0;

    // Second step of counting sort:
    for (int i = 0; i < numCells; i++) {
        prefixSum        = cellHistogram[i];
        cellHistogram[i] = totalSum;
        totalSum        += prefixSum;
    }

    // Final step of counting sort:
    for (int i = 0; i < numParticles; i++) {

        global ParticlePosition* pp = &particleToCell[i];

        int key = sub2ind(pp->cellI, pp->cellJ, pp->cellK, cellsX, cellsY);
        int j   = cellHistogram[key];
        
        /*
        sortedParticleToCell[j].particleIndex = pp->particleIndex;
        sortedParticleToCell[j].cellI         = pp->cellI;
        sortedParticleToCell[j].cellJ         = pp->cellJ;
        sortedParticleToCell[j].cellK         = pp->cellK;
        */
        sortedParticleToCell[j] = *pp;
        
        cellHistogram[key] += 1;
    }
    
    // Now, the ParticlePosition entries of sortedParticleToCell are sorted in
    // ascending order by the value sub2ind(pp[i].cellI, pp[i].cellJ, pp[i].cellK, cellsX, cellsY),
    // where pp is an instance of ParticlePosition  at index i, such that
    // 0 <= i < numParticles.

    // Record the offsets per grid cell:
    // The i-th entry of the gridCellOffsets contains the start and length
    // of the i-th linearized grid cell in sortedParticleToCell

    int lengthCount = 1;
    int cellStart   = 0;
    
    for (int i = 0; i < (numParticles - 1); i++) {

        global ParticlePosition* currentP = &sortedParticleToCell[i];
        global ParticlePosition* nextP    = &sortedParticleToCell[i+1];

        int currentKey = sub2ind(currentP->cellI, currentP->cellJ, currentP->cellK, cellsX, cellsY);
        int nextKey    = sub2ind(nextP->cellI, nextP->cellJ, nextP->cellK, cellsX, cellsY);
        
        if (currentKey == nextKey) {

            lengthCount++;

        } else {
            
            gridCellOffsets[currentKey].start  = cellStart;
            gridCellOffsets[currentKey].length = lengthCount;
            
            cellStart   = i + 1;
            lengthCount = 1;
        }
    }

    /*
    // Dump everything out for verification:
    for (int i = 0; i < numParticles; i++) {
        global ParticlePosition* spp = &sortedParticleToCell[i];
        int key = sub2ind(spp->cellI, spp->cellJ, spp->cellK, cellsX, cellsY);
        printf("P [%d] :: particleIndex = %d, key = %d \n", i, spp->particleIndex, key);
    }
    
    printf("numCells = %d\n", numCells);
    
    for (int i = 0; i < numCells; i++) {
        global GridCellOffset* gco = &gridCellOffsets[i];
        printf("C [%d] :: start = %d, length = %d\n", i, gco->start, gco->length);
    }
    */
}

/**
 * From the Macklin & Muller paper: SPH density estimation
 * 
 * @param [in]  Particle* particles
 * @param [in]  ParticlePosition* sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX
 * @param [in]  int cellsY
 * @param [in]  int cellsZ
 * @param [out] float* density
 */
void kernel SPHEstimateDensity(global Particle* particles
                              ,global ParticlePosition* sortedParticleToCell
                              ,global GridCellOffset* gridCellOffsets
                              ,int cellsX
                              ,int cellsY
                              ,int cellsZ
                              ,global float* density)
{
    int i = get_global_id(0);
    global Particle *p = &particles[i];
    
    // 27 possible neighbors to search
    int neighbors[27];
    
    // Convert a linear index z into (i, j, k):
    int3 cellSubscript = ind2sub(i, cellsX, cellsY);

    int neighborCount = getNeighborsBySubscript(sortedParticleToCell
                                               ,gridCellOffsets
                                               ,cellsX
                                               ,cellsY
                                               ,cellsZ
                                               ,cellSubscript
                                               ,neighbors);
    
}