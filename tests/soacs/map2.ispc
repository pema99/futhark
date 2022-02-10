//Wrappers to generate valid ispc code
typedef int8 char;
typedef int64 int64_t;
typedef int int32_t;
typedef uint32 uint32_t;


struct imemblock {
    int *references;
    unsigned char *mem;
    int64_t size;
    const char *desc;
};

struct iargs {
    int64_t dz2080U_4583;
};

//All other math functions should be included
static inline uint32_t add32(uint32_t x, uint32_t y) {
  return x + y;
}
//...more math functions

export void parloop(uniform int64_t start, uniform int64_t end,
                    imemblock * uniform input, imemblock * uniform out,
                    iargs * uniform iiargs) {
    uniform int64_t start_4596;
    uniform int64_t end_4597;

    start_4596 = start;
    end_4597 = end;

    uniform int64_t n_4598 = end_4597 - start_4596;
    //
    imemblock *a_mem_4590 = (imemblock *) input;
    imemblock *mem_4593 = (imemblock *) out;
    //
    foreach (SegMap_i_4599 = 0...n_4598) {
        int64_t slice_4600 =iiargs -> dz2080U_4583; //dz2080U_4583;
        int64_t gtid_4589 = start_4596 + SegMap_i_4599;
        int64_t remnant_4601 = start_4596 + SegMap_i_4599 - gtid_4589;
        int32_t x_4586;

        //x_4586 = ((int32_t *) a_mem_4590.mem)[gtid_4589];
        x_4586 = ((int32_t *) a_mem_4590->mem)[gtid_4589];

        int32_t defunc_0_f_res_4587 = add32(2, x_4586);

        ((int32_t *) mem_4593->mem)[gtid_4589] = defunc_0_f_res_4587;
    }
}
